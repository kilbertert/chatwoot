# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wecom::HandoffQueryService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_wecom, account: account, open_kfid: 'wk_test_handoff') }
  let(:inbox) { channel.inbox }
  let(:agent) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'wm_user_test') }

  describe '#perform' do
    context 'when channel not found' do
      it 'returns handoff: false with reason: channel_not_found' do
        result = described_class.new(open_kfid: 'non_existent', external_userid: 'wm_x').perform
        expect(result).to eq(handoff: false, reason: 'channel_not_found')
      end
    end

    context 'when contact_inbox not found' do
      it 'returns handoff: false with reason: no_conversation' do
        channel

        result = described_class.new(open_kfid: 'wk_test_handoff', external_userid: 'wm_unknown').perform
        expect(result).to eq(handoff: false, reason: 'no_conversation')
      end
    end

    context 'when conversation unassigned' do
      it 'returns handoff: false with reason: unassigned' do
        create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: nil)
        result = described_class.new(open_kfid: 'wk_test_handoff', external_userid: 'wm_user_test').perform
        expect(result).to eq(handoff: false, reason: 'unassigned')
      end
    end

    context 'when assignee online' do
      it 'returns handoff: true' do
        conv = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent)
        allow(OnlineStatusTracker).to receive(:get_available_user_ids).with(account.id).and_return([agent.id])
        result = described_class.new(open_kfid: 'wk_test_handoff', external_userid: 'wm_user_test').perform
        expect(result[:handoff]).to be true
        expect(result[:reason]).to eq('agent_online')
        expect(result[:assignee_id]).to eq(agent.id)
      end
    end

    context 'when assignee offline' do
      it 'returns handoff: false with reason: agent_offline' do
        create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent)
        allow(OnlineStatusTracker).to receive(:get_available_user_ids).with(account.id).and_return([])
        result = described_class.new(open_kfid: 'wk_test_handoff', external_userid: 'wm_user_test').perform
        expect(result).to include(handoff: false, reason: 'agent_offline')
        expect(result[:assignee_id]).to eq(agent.id)
      end
    end
  end
end
