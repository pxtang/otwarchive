module Ao3Backup
  class SessionService
    MAX_GENERATIONS = 3

    def initialize(clock: -> { Time.current }, dispatcher: ->(id, generation) { Resque.enqueue(FetchJob, id, generation) }, policy: SelectionPolicy.new)
      @clock, @dispatcher, @policy = clock, dispatcher, policy
    end

    def start(owner:, url:)
      identity = SourceIdentity.parse(url)
      session = ImportSession.create!(identity.to_h.merge(owner: owner, expires_at: nil))
      dispatch(session)
      session.reload
    end

    def dispatch(session)
      generation = session.generation
      return session unless session.state == "queued" && session.dispatch_pending
      begin
        result = @dispatcher.call(session.id, generation)
        raise Error.new(:dispatch_failed, "The fetch could not be queued. Try dispatch again.") if result == false
        session.with_lock do
          session.update!(dispatch_pending: false, error_code: nil, error_message: nil) if session.generation == generation && session.state == "queued"
        end
      rescue StandardError
        session.with_lock do
          if session.generation == generation && session.state == "queued"
            session.update!(dispatch_pending: true, error_code: "dispatch_failed", error_message: "The fetch could not be queued. Try dispatch again.")
          end
        end
      end
      session
    end

    def expire(session)
      session
    end

    def cancel(session)
      session.with_lock do
        session.update!(state: "cancelled", dispatch_pending: false) unless %w[expired cancelled].include?(session.state)
      end
      session
    end

    def retry_fetch(session)
      expire(session)
      session.with_lock do
        raise Error.new(:invalid_state, "This review has expired or was cancelled. Start a new review.") if %w[expired cancelled].include?(session.state)
        if session.retry_not_before && @clock.call < session.retry_not_before
          raise Error.new(:retry_later, "The source requested a wait before retrying. Try after #{session.retry_not_before.utc.iso8601}.")
        end
        raise Error.new(:retry_limit, "This review has reached its three fetch attempts. Start a new review later.") if session.generation >= MAX_GENERATIONS
        session.update!(generation: session.generation + 1, state: "queued", dispatch_pending: true,
                        snapshot_digest: nil, selection: nil, selection_revision: 0,
                        error_code: nil, error_message: nil, retry_after: nil, retry_not_before: nil)
      end
      dispatch(session)
    end

    def update_selection(session, revision:, digest:, edits:)
      expire(session)
      session.with_lock do
        raise Error.new(:invalid_state, "This review is not ready for editing.") unless session.state == "ready"
        unless revision.to_s.match?(/\A\d+\z/) && session.selection_revision == revision.to_i && session.snapshot_digest == digest
          raise Error.new(:stale_revision, "This review changed in another tab. Reload before editing.")
        end
        ImportSession.logger.silence do
          selected = @policy.update(session.selection, edits)
          session.update!(selection: selected, selection_revision: session.selection_revision + 1)
        end
      end
      session
    end

  end
end
