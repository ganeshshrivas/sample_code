module EmailValidatable
  extend ActiveSupport::Concern

  included do

    VALID_EMAIL_REGEX = /^(?:[^@\s]+)@(?:(?:[-a-z0-9]+\.)+[a-z]{2,})$/i

    DISALLOWED_EMAIL_USERS = %w[postmaster nospam abuse spam noreply donotreply subscribe unsubscribe remove majordomo do-not-reply listserv anonymous-comment]
    DISALLOWED_EMAIL_USER_SUFFIXES = %w[-unsubscribe -subscribe -request -owner -noreply -no-reply]
    DISALLOWED_EMAIL_HOST_PREFIXES = %w[lists. list.]
    DISALLOWED_EMAIL_HOSTS = %w[yahoogroups.com googlegroups.com]
    DISALLOWED_EMAILS = %w[notifier@groupsite.com www@groupsite.com info@groupsite.com billing@groupsite.com cxmailer@groupsite.com
      welcome@groupsite.com support@groupsite.com sales@groupsite.com advertise@groupsite.com
      info@evite.com usa0366@fedexkinkos.com info@junkyarddawgs.ca nmrs.deborah@yahoo.com]
    DISALLOWED_EMAIL_REGEXES = [ /^(?:[^@\s]+)-(?:[0-9]+)@craigslist\.org$/i ]

    validates_presence_of :email
    validates_format_of :email, :with => VALID_EMAIL_REGEX, :multiline => true
    validate :email_is_allowed
    validate :email_is_unique, on: :create
  end

  def email_is_unique
    email = Email.with_deleted.find_by_email self.email&.downcase
    errors.add(:email, "This email is already in use") if email.present?
  end

  def email_is_allowed
    errors.add(:email, "Email not allowed") if self.class.disallow?(email)
  end

  module ClassMethods
    def disallow?(email)
      email = email.to_s.downcase
      return true if DISALLOWED_EMAILS.include? email
      DISALLOWED_EMAIL_USERS.each do |w|
        return true if email.starts_with?(w+'@')
      end
      DISALLOWED_EMAIL_USER_SUFFIXES.each do |w|
        return true if email.include?(w+'@')
      end
      DISALLOWED_EMAIL_HOSTS.each do |w|
        return true if email.ends_with?('@'+w)
      end
      DISALLOWED_EMAIL_HOST_PREFIXES.each do |w|
        return true if email.include?('@'+w)
      end
      DISALLOWED_EMAIL_REGEXES.each do |r|
        return true if email =~ r
      end

      false
    end
  end

end
