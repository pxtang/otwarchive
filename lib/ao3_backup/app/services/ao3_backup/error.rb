module Ao3Backup
  class Error < StandardError
    attr_reader :code, :retry_after
    def initialize(code, message, retry_after: nil)
      @code, @retry_after = code.to_s, retry_after
      super(message)
    end
  end
end
