class PreserveUnknownRefundedCash < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE appointments
      SET refunded_amount_cents = NULL
      WHERE refunded_amount_cents IS NOT NULL
        AND refund_data @? '$.items[*] ? (@.status == "succeeded" && @.amount_cents > 0 &&
          (!(exists(@.payer_refund_cents)) || @.payer_refund_cents == null))'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE appointments
      SET refunded_amount_cents = (
        SELECT COALESCE(SUM((item ->> 'payer_refund_cents')::bigint), 0)
        FROM jsonb_array_elements(refund_data -> 'items') AS item
        WHERE item ->> 'status' = 'succeeded'
      )
      WHERE refunded_amount_cents IS NULL
    SQL
  end
end
