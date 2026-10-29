module Ao3Backup
  class LocalTagResolver
    TYPES = %w[Rating ArchiveWarning Category Fandom Relationship Character Freeform].freeze

    def call(candidate)
      type, name = candidate.values_at("type", "name")
      raise Error.new(:invalid_selection, "Unsupported tag type.") unless TYPES.include?(type)
      tag = Tag.find_by(name: name)
      status = if tag.nil? then "new"
               elsif tag.type != type then "collision"
               elsif %w[Rating ArchiveWarning Category].include?(type) && !tag.canonical? then "invalid_local"
               else "existing" end
      candidate.merge("status" => status, "local_id" => status == "existing" ? tag.id : nil,
                      "local_name" => tag&.name, "local_type" => tag&.type)
    end
  end
end
