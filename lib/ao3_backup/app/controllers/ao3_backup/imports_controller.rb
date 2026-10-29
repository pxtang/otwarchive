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
      ::Rails.application.routes.named_routes.helper_names.each do |name|
        define_method(name) { |*args, **options| main_app.public_send(name, *args, **options) }
      end
    end)
    before_action :authenticate_user!
    before_action :authorize_importer!
    before_action :load_session, except: [:index, :create]

    def index
      @sessions = ImportSession.where(owner: current_user).order(created_at: :desc).limit(10)
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
      session_service.update_selection(@import_session, revision: params[:revision], digest: params[:digest], edits: edits)
      redirect_to import_session_path(@import_session), notice: "Review choices updated. No archive content has been saved."
    rescue Error, ActionController::ParameterMissing => error
      flash.now[:error] = error.message
      @import_session.reload
      prepare_review
      render :show, status: :unprocessable_entity
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
