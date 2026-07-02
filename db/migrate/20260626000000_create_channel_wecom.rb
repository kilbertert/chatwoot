class CreateChannelWecom < ActiveRecord::Migration[7.1]
  def change
    create_table :channel_wecom do |t|
      t.string  :corp_id, null: false
      t.string  :open_kfid, null: false
      t.string  :wecom_ai_service_url, null: false
      t.string  :wecom_ai_secret
      t.string  :bot_name
      t.integer :account_id, null: false
      t.timestamps
      t.index ['open_kfid'], name: 'idx_channel_wecom_on_open_kfid', unique: true
      t.index ['account_id'], name: 'idx_channel_wecom_on_account_id'
    end
  end
end
