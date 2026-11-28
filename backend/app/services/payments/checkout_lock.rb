class Payments::CheckoutLock
  def self.synchronize(payment_no)
    # PostgreSQL session locks are reentrant on the same connection.
    held = ActiveSupport::IsolatedExecutionState[:booking_checkout_locks] ||= Set.new
    raise Payments::CheckoutInFlight unless held.add?(payment_no)

    begin
      # The session lock spans the channel call without keeping a row lock or transaction open.
      ApplicationRecord.connection_pool.with_connection do |db|
        key = Digest::SHA256.digest("booking.checkout:#{payment_no}").unpack1("q>")
        raise Payments::CheckoutInFlight unless db.get_advisory_lock(key)

        begin
          yield
        ensure
          db.release_advisory_lock(key)
        end
      end
    ensure
      held.delete(payment_no)
    end
  end
end
