class CreateLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :links do |t|
      t.references :app, foreign_key: { on_delete: :restrict }, index: false
      t.string :position, null: false
      t.string :name, null: false
      t.string :link_type, null: false, default: "none"
      t.text :url
      t.jsonb :params, null: false, default: {}
      t.integer :sort_order, null: false, default: 0
      t.string :status, null: false, default: "active"
      t.timestamps

      t.index %i[app_id position status sort_order id], name: "index_links_on_app_position_status_and_order"
      t.check_constraint "link_type IN ('none','page','tab','webview','miniprogram','contact')", name: "links_type_valid"
      t.check_constraint "status IN ('active','disabled')", name: "links_status_valid"
      t.check_constraint "jsonb_typeof(params) = 'object'", name: "links_params_object"
    end
  end
end
