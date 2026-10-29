module Ao3Backup
  class SelectionPolicy
    include ::HtmlCleaner
    def initialize(resolver: LocalTagResolver.new)
      @resolver = resolver
    end

    def initial(manifest)
      authors = manifest.fetch("authors").map { |name| { "type" => "Freeform", "name" => name, "author" => true } }
      candidates = (authors + manifest.fetch("tags")).each_with_index.map do |tag, index|
        resolved = @resolver.call(tag)
        resolved.merge("id" => index.to_s,
                       "keep" => tag["author"] == true || (resolved["status"] == "existing" && !%w[Rating ArchiveWarning].include?(tag["type"])))
      end
      candidates.sort_by! { |tag| [tag["author"] ? 0 : tag["status"] == "existing" ? 1 : 2, tag["id"].to_i] }
      { "schema_version" => 1,
        "scalars" => manifest.fetch("scalars").transform_values { |value| { "keep" => true, "value" => value, "replacement" => nil } },
        "chapters" => manifest.fetch("chapters").map do |chapter|
          chapter.merge("fields" => chapter.slice("title", "summary", "notes", "endnotes").transform_values { |value| { "keep" => true, "value" => value } })
        end,
        "tags" => candidates }
    end

    # Accept a complete revision of the current choices; never reapply defaults.
    def update(current, edits)
      unless edits.is_a?(Hash) && edits.fetch("scalars", {}).is_a?(Hash) && edits.fetch("chapters", {}).is_a?(Hash)
        raise Error.new(:invalid_selection, "Selection edits must be structured metadata fields.")
      end
      result = JSON.parse(JSON.generate(current))
      raise Error.new(:invalid_selection, "Unknown selection fields.") unless (edits.keys - %w[scalars chapters tags additional_tags required_tags]).empty?
      edits.fetch("scalars", {}).each do |name, edit|
        raise Error.new(:invalid_selection, "Unknown metadata field.") unless result["scalars"].key?(name)
        result["scalars"][name] = checked_field(edit, result["scalars"][name], name)
      end
      if edits.key?("tags")
        raise Error.new(:invalid_selection, "Tag choices must be a list.") unless edits["tags"].is_a?(Array)
        raise Error.new(:invalid_selection, "Invalid tag choices.") unless edits["tags"].all? { |tag| tag.is_a?(Hash) }
        by_id = result["tags"].index_by { |tag| tag["id"] }
        unless edits["tags"].all? { |tag| tag["id"].is_a?(String) && by_id.key?(tag["id"]) }
          raise Error.new(:invalid_selection, "Unknown or malformed tag choice identity.")
        end
        tag_edits = edits["tags"].empty? ? by_id.keys.map { |id| { "id" => id, "keep" => false } } : edits["tags"]
        raise Error.new(:invalid_selection, "Missing or duplicate tag choices.") unless tag_edits.map { |tag| tag["id"] }.sort == by_id.keys.sort
        result["tags"] = tag_edits.map do |edit|
          unless edit.is_a?(Hash) && (edit.keys - %w[id name keep type]).empty?
            raise Error.new(:invalid_selection, "Unknown tag edit fields.")
          end
          raise Error.new(:invalid_selection, "Every tag choice must include an explicit keep boolean.") unless edit.key?("keep")
          old = by_id.fetch(edit["id"])
          raise Error.new(:invalid_selection, "Tag type cannot be changed.") if edit.key?("type") && edit["type"] != old["type"]
          name = edit.fetch("name", old["name"])
          raise Error.new(:invalid_selection, "Tag name is empty or too long.") unless name.is_a?(String) && name.strip.present? && name.length <= ArchiveConfig.TAG_MAX
          @resolver.call(old.merge("name" => name.strip, "keep" => boolean(edit.fetch("keep"))))
        end
        # Submitted order cannot move author attribution below other tags.
        result["tags"].sort_by! { |tag| current["tags"].index { |old| old["id"] == tag["id"] } }
      end
      if edits.key?("additional_tags")
        additions = edits["additional_tags"]
        raise Error.new(:invalid_selection, "Invalid additional tag choices.") unless additions.is_a?(Hash) && (additions.keys - %w[Rating ArchiveWarning Category Fandom]).empty?
        additions.each do |type, values|
          raise Error.new(:invalid_selection, "Invalid additional tag choices.") unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) }
          values = values.reject(&:blank?).map(&:strip).uniq
          values.each do |name|
            raise Error.new(:invalid_selection, "Tag name is too long.") if name.length > ArchiveConfig.TAG_MAX
            resolved = @resolver.call("type" => type, "name" => name)
            existing = result["tags"].find { |tag| tag["type"] == type && ((resolved["local_id"] && tag["local_id"] == resolved["local_id"]) || tag["name"].casecmp?(name)) }
            if existing
              existing["keep"] = true
            else
              id = "added-#{SecureRandom.uuid}"
              result["tags"] << @resolver.call("id" => id, "type" => type, "name" => name, "author" => false, "keep" => true)
            end
          end
        end
      end
      if edits["required_tags"]
        %w[Rating ArchiveWarning Fandom].each do |type|
          raise Error.new(:invalid_selection, "Choose at least one #{type == 'ArchiveWarning' ? 'archive warning' : type.downcase}.") unless result["tags"].any? { |tag| tag["type"] == type && tag["keep"] }
        end
        raise Error.new(:invalid_selection, "Choose only one rating.") if result["tags"].count { |tag| tag["type"] == "Rating" && tag["keep"] } > 1
      end
      edits.fetch("chapters", {}).each do |position, fields|
        chapter = result["chapters"].find { |item| item["position"].to_s == position.to_s }
        raise Error.new(:invalid_selection, "Unknown chapter.") unless chapter
        raise Error.new(:invalid_selection, "Chapter fields must be structured edits.") unless fields.is_a?(Hash)
        fields.each do |name, edit|
          raise Error.new(:invalid_selection, "Chapter structure and bodies cannot be edited.") unless chapter["fields"].key?(name)
          chapter["fields"][name] = checked_field(edit, chapter["fields"][name], name)
        end
      end
      validate!(result)
      result
    end

    def validate!(selection)
      %w[title language].each do |name|
        field = selection.fetch("scalars").fetch(name)
        value = field["keep"] ? field["value"] : field["replacement"]
        raise Error.new(:replacement_required, "Choose an explicit local #{name} replacement after removing the source value.") if value.to_s.strip.empty?
      end
      language = selection.fetch("scalars").fetch("language")
      local_language = language["keep"] ? language["value"] : language["replacement"]
      unless Language.find_by(name: local_language)
        raise Error.new(:replacement_required, "Choose an available local language by its exact name.")
      end
      expected_field = selection.fetch("scalars").fetch("expected_chapters")
      expected = expected_field["keep"] ? expected_field["value"] : expected_field["replacement"]
      if expected.present? && expected.to_i < selection.fetch("chapters").length
        raise Error.new(:invalid_selection, "Expected total cannot be smaller than the published chapter count.")
      end
      selection.fetch("tags").select { |tag| tag["keep"] }.each do |tag|
        if %w[collision invalid_local].include?(tag["status"]) || (%w[Rating ArchiveWarning Category].include?(tag["type"]) && tag["status"] != "existing")
          raise Error.new(:invalid_selection, "Resolve the local #{tag['type']} choice for #{tag['name']} before reviewing it.")
        end
      end
      selection
    end

    def proposed(selection)
      scalars = selection.fetch("scalars").transform_values { |field| field["keep"] ? field["value"] : field["replacement"] }
      seen = {}
      tags = selection.fetch("tags").select { |tag| tag["keep"] }.reject do |tag|
        key = tag["local_id"] ? ["id", tag["local_id"]] : [tag["type"], tag["name"].downcase]
        seen.key?(key).tap { seen[key] = true }
      end
      { "schema_version" => 1, "scalars" => scalars, "tags" => tags,
        "chapters" => selection.fetch("chapters").map do |chapter|
          chapter.slice("position", "source_chapter_id", "content").merge(chapter.fetch("fields").transform_values { |field| field["keep"] ? field["value"] : nil })
        end }
    end

    def safe_display_value(name, value)
      sanitize_value(name, value)
    end

    private

    def boolean(value)
      return true if value == true || value == "1"
      return false if value == false || value == "0"
      raise Error.new(:invalid_selection, "Keep choices must be explicit booleans.")
    end

    def checked_field(edit, old, name)
      raise Error.new(:invalid_selection, "Unknown metadata edit fields.") unless edit.is_a?(Hash) && (edit.keys - %w[keep value replacement]).empty?
      field = old.merge(edit)
      field["keep"] = boolean(field.fetch("keep"))
      [field["value"], field["replacement"]].each do |value|
        unless value.nil? || value.is_a?(String) || value.is_a?(Integer)
          raise Error.new(:invalid_selection, "Metadata must be plain text or a number.")
        end
        raise Error.new(:invalid_selection, "Metadata exceeds local field limits.") if value.to_s.length > ArchiveConfig.CONTENT_MAX
      end
      max = case name
            when "title" then ArchiveConfig.TITLE_MAX
            when "summary" then ArchiveConfig.SUMMARY_MAX
            when "notes", "endnotes" then ArchiveConfig.NOTES_MAX
            else 2080 end
      %w[value replacement].each do |key|
        value = field[key]
        next if value.nil?
        raise Error.new(:invalid_selection, "#{name} exceeds local field limits.") if value.to_s.length > max
        if %w[published_at status_date].include?(name) && value.to_s.present?
          begin
            Date.iso8601(value.to_s)
          rescue Date::Error
            raise Error.new(:invalid_selection, "#{name} must be a valid ISO date.")
          end
        elsif name == "expected_chapters" && value.to_s.present?
          raise Error.new(:invalid_selection, "Expected chapters must be a positive integer or absent.") unless value.to_s.match?(/\A[1-9]\d*\z/)
        elsif %w[summary notes endnotes].include?(name)
          field[key] = sanitize_value(name, value.to_s)
        end
      end
      field
    end
  end
end
