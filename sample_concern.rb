# frozen_string_literal: true

module AjaxSearchInputHelper
  extend ActiveSupport::Concern

  def parseSearchText(search_text:)
    first_name, last_name, email_address = nil
    if search_text.present?
      search_text = search_text.strip
      if search_text.include?(",")
        last_name, first_name = search_text.split(",")
      elsif search_text.include?(" ")
        first_name, last_name = search_text.split
      elsif search_text.include?("@")
        email_address = search_text
      else
        last_name = search_text
        first_name = search_text
      end
    end

    last_name&.strip!
    first_name&.strip!
    email_address&.strip!

    return OpenStruct.new({first_name: first_name, last_name: last_name, email: email_address})
  end

  def parseMemberSearchText(search_text:)
    search_query, email_address = nil
    if search_text.present?
      search_text = search_text.strip
      if search_text.include?("@")
        email_address = search_text
      else
        search_query = search_text&.strip
      end
    end
    return OpenStruct.new({search_query: search_query, email: email_address})
  end

end