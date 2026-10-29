module Ao3Backup
  class ImportsController < ::ApplicationController
    prepend_view_path Engine.root.join("app/views")
    layout "application"
    rescue_from ActiveRecord::RecordNotFound do
      head :not_found
    end
    rescue_from ActionController::InvalidAuthenticityToken do
      redirect_to main_app.auth_error_path
    end
    # Forward only named host helpers. Including its full url_helpers module
    # replaces the engine's _routes and sends optimized engine forms to unrelated
    # host routes (for example /cable).
    helper(Module.new do
      def allow_tinymce?(controller)
        controller.controller_path == "ao3_backup/imports" && %w[show update].include?(controller.action_name)
      end

      ::Rails.application.routes.named_routes.helper_names.each do |name|
        define_method(name) { |*args, **options| main_app.public_send(name, *args, **options) }
      end
    end)
    prepend_before_action :capture_rich_values, only: :update
    before_action :restore_rich_values, only: :update
    before_action :authenticate_user!
    before_action :authorize_importer!
    before_action :load_session, except: [:index, :create]

    def index
      @sessions = ImportSession.where(owner: current_user).order(created_at: :desc).limit(10).to_a
      @sessions.each { |session| session_service.expire(session) }
    end

    def create
      session = session_service.start(owner: current_user, url: params[:source_url])
      redirect_to import_session_path(session)
    rescue Error => error
      flash.now[:error] = error.message
      @sessions = ImportSession.where(owner: current_user).order(created_at: :desc).limit(10)
      render :index, status: :unprocessable_entity
    end

    def show
      session_service.expire(@import_session)
      respond_to do |format|
        format.html { prepare_review }
        format.json do
          render json: @import_session.slice(:state, :generation, :selection_revision, :expires_at, :error_code, :error_message, :dispatch_pending)
        end
      end
    end

    def update
      submitted = params.require(:selection)
      raise Error.new(:invalid_selection, "Selection must contain structured fields.") unless submitted.is_a?(ActionController::Parameters)
      edits = submitted.to_unsafe_h
      if edits["tags"].is_a?(Hash)
        edits["tags"] = edits["tags"].values
      end
      if params[:layout] == "new_work"
        additions = params[:additional_tags].is_a?(ActionController::Parameters) ? params[:additional_tags].to_unsafe_h : {}
        edits["additional_tags"] = additions
        edits["required_tags"] = true unless params[:switch_layout].present?
      end
      session_service.update_selection(@import_session, revision: params[:revision], digest: params[:digest], edits: edits)
      redirect_to import_session_path(@import_session, layout: params[:switch_layout].presence || params[:layout]), notice: "Review choices updated. No archive content has been saved."
    rescue Error, ActionController::ParameterMissing => error
      flash.now[:error] = error.message
      @import_session.reload
      prepare_review
      restore_submitted_review(edits) if @selection && edits.is_a?(Hash) && params[:revision].to_s == @import_session.selection_revision.to_s && params[:digest] == @import_session.snapshot_digest
      render :show, status: :unprocessable_entity
    end

    def confirm_delete
    end

    def destroy
      @import_session.with_lock { @import_session.destroy! }
      redirect_to main_app.ao3_backup_path, notice: "Review deleted."
    end

    def cancel
      session_service.cancel(@import_session)
      redirect_to import_session_path(@import_session)
    end

    def retry_fetch
      session_service.retry_fetch(@import_session)
      redirect_to import_session_path(@import_session)
    rescue Error => error
      redirect_to import_session_path(@import_session), alert: error.message
    end

    def recover_dispatch
      session_service.expire(@import_session)
      session_service.dispatch(@import_session)
      redirect_to import_session_path(@import_session)
    end

    private

    # Rebuild only display fields. Never persist invalid input or use it in the
    # proposed output, and sanitize rich text before it reaches the editor.
    def restore_submitted_review(edits)
      display = JSON.parse(JSON.generate(@selection))
      policy = SelectionPolicy.new
      apply_field = lambda do |field, submitted, name|
        next unless submitted.is_a?(Hash)
        %w[value replacement].each do |key|
          next unless submitted[key].is_a?(String)
          field[key] = %w[summary notes endnotes].include?(name) ? policy.safe_display_value(name, submitted[key]) : submitted[key]
        end
        field["keep"] = submitted["keep"] == "1" || submitted["keep"] == true if submitted.key?("keep")
      end
      if edits["scalars"].is_a?(Hash)
        edits["scalars"].each { |name, field| apply_field.call(display["scalars"][name], field, name) if display["scalars"].key?(name) }
      end
      if edits["chapters"].is_a?(Hash)
        edits["chapters"].each do |position, fields|
          chapter = display["chapters"].find { |item| item["position"].to_s == position.to_s }
          next unless chapter && fields.is_a?(Hash)
          fields.each { |name, field| apply_field.call(chapter["fields"][name], field, name) if chapter["fields"].key?(name) }
        end
      end
      if edits["tags"].is_a?(Array)
        edits["tags"].each do |edit|
          next unless edit.is_a?(Hash)
          tag = display["tags"].find { |item| item["id"] == edit["id"] }
          next unless tag
          tag["name"] = edit["name"] if edit["name"].is_a?(String)
          tag["keep"] = edit["keep"] == "1" || edit["keep"] == true if edit.key?("keep")
        end
      end
      @ephemeral_tag_ids = []
      if edits["additional_tags"].is_a?(Hash)
        edits["additional_tags"].each do |type, names|
          next unless %w[Rating ArchiveWarning Category Fandom].include?(type) && names.is_a?(Array)
          names.each do |name|
            next unless name.is_a?(String) && name.present?
            resolved = LocalTagResolver.new.call("type" => type, "name" => name)
            tag = display["tags"].find { |item| item["type"] == type && ((resolved["local_id"] && item["local_id"] == resolved["local_id"]) || item["name"].casecmp?(name)) }
            if tag
              tag["keep"] = true
            else
              id = "display-#{SecureRandom.uuid}"
              display["tags"] << resolved.merge("id" => id, "author" => false, "keep" => true)
              @ephemeral_tag_ids << id
            end
          end
        end
      end
      @selection = display
    end

    # The host sanitizer treats nested keys named "value" as plain text. Preserve
    # only these fields until SelectionPolicy sanitizes them by their field name.
    def capture_rich_values
      @rich_values = []
      selection = params[:selection]
      return unless selection.is_a?(ActionController::Parameters)
      collect_rich_values(selection[:scalars], ["scalars"])
      chapters = selection[:chapters]
      if chapters.is_a?(ActionController::Parameters)
        chapters.each { |position, fields| collect_rich_values(fields, ["chapters", position]) }
      end
    end

    def collect_rich_values(fields, prefix)
      return unless fields.is_a?(ActionController::Parameters)
      %w[summary notes endnotes].each do |name|
        field = fields[name]
        next unless field.is_a?(ActionController::Parameters)
        %w[value replacement].each do |key|
          @rich_values << [prefix + [name, key], field[key]] if field[key].is_a?(String)
        end
      end
    end

    def restore_rich_values
      @rich_values.each do |path, value|
        target = params[:selection]
        path[0...-1].each { |key| target = target[key] if target.is_a?(ActionController::Parameters) }
        target[path.last] = value if target.is_a?(ActionController::Parameters)
      end
    end

    def authorize_importer!
      head :forbidden unless Access.allowed?(current_user)
    end

    def load_session
      @import_session = ImportSession.where(owner: current_user).find(params[:id])
    end

    def session_service
      SessionService.new
    end

    def prepare_review
      return unless @import_session.state == "ready"
      @snapshot = @import_session.current_snapshot
      @selection = @import_session.selection
      @proposed = SelectionPolicy.new.proposed(@selection)
      @languages = Language.order(:name).pluck(:name)
    end
  end
end
