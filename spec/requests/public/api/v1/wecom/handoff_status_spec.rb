# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WeCom handoff status', type: :request do
  let(:account) { create(:account) }
  let!(:wecom_channel) { create(:channel_wecom, account: account, wecom_ai_secret: 'spec_test_secret') }
  let(:open_kfid) { wecom_channel.open_kfid }
  let(:external_userid) { 'wm_test' }
  let(:query) { "open_kfid=#{open_kfid}&external_userid=#{external_userid}" }
  let(:signature) { signature_for(query) }

  def signature_for(query_string, secret = wecom_channel.wecom_ai_secret)
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), secret, query_string)
  end

  def get_handoff_status(query_string = query, signature_header = signature)
    headers = {}
    headers['X-WecomAI-Signature'] = signature_header unless signature_header.nil?

    get "/public/api/v1/wecom/handoff_status?#{query_string}", headers: headers
  end

  describe 'GET /public/api/v1/wecom/handoff_status' do
    context 'with valid HMAC signature' do
      it 'returns the handoff status' do
        get_handoff_status

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('handoff' => false, 'reason' => 'no_conversation')
      end
    end

    context 'with missing HMAC signature' do
      it 'returns unauthorized' do
        get_handoff_status(query, nil)

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to include('error' => 'invalid signature')
      end
    end

    context 'with invalid HMAC signature' do
      it 'returns unauthorized' do
        get_handoff_status(query, 'invalid')

        expect(response).to have_http_status(:unauthorized)
        expect(response.parsed_body).to include('error' => 'invalid signature')
      end
    end
  end
end
