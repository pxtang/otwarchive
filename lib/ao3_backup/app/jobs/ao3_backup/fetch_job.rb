module Ao3Backup
  class FetchJob
    @queue = :utilities

    def self.perform(session_id, generation)
      new.call(session_id, generation)
    end

    def initialize(provider: Provider.new, parser: Parser.new, policy: SelectionPolicy.new, clock: -> { Time.current })
      @provider, @parser, @policy, @clock = provider, parser, policy, clock
    end

    def call(session_id, generation)
      previous_user = User.current_user
      session = ImportSession.find_by(id: session_id)
      return unless session
      SessionService.new(clock: @clock).expire(session)
      claimed = false
      session.with_lock do
        if session.generation == generation && session.state == "queued"
          session.update!(state: "fetching", dispatch_pending: false, error_code: nil, error_message: nil)
          claimed = true
        end
      end
      return unless claimed
      # All solver I/O happens after releasing the SQL lock/transaction.
      ImportSession.logger.silence do
        page = @provider.call(SourceIdentity.parse(session.canonical_url))
        manifest = @parser.call(page)
        selection = @policy.initial(manifest)
        session.with_lock do
          if session.generation == generation && session.state == "fetching" && @clock.call < session.expires_at
            session.snapshots.create!(generation: generation, digest: page.digest, manifest: manifest, retrieved_at: page.retrieved_at)
            session.update!(state: "ready", snapshot_digest: page.digest, selection: selection, selection_revision: 0)
          elsif @clock.call >= session.expires_at
            SessionService.new(clock: @clock).expire(session)
          end
        end
      end
    rescue StandardError => error
      if session
        SessionService.new(clock: @clock).expire(session)
        session.with_lock do
          if session.generation == generation && session.state == "fetching"
            typed = error.is_a?(Error) ? error : Error.new(:fetch_failed, "The work could not be inspected. Retry the fetch or contact the maintainer.")
            session.update!(state: "fetch_failed", error_code: typed.code, error_message: typed.message,
                            retry_after: typed.retry_after, retry_not_before: retry_time(typed.retry_after))
          end
        end
      end
    ensure
      User.current_user = previous_user
    end

    private

    def retry_time(value)
      return nil if value.to_s.empty?
      return @clock.call + value.to_i.seconds if value.to_s.match?(/\A\d+\z/)
      Time.httpdate(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
