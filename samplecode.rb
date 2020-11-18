require 'csv'

class Membership < ApplicationRecord
  acts_as_paranoid

  include MembershipSettings::Permissions
  include AuditConcern
  # ----------------------------------------------------
  # GS1 
  LEGACY_HIDE_CONTACT_OPTIONS = [["all group members", 0], ["people I endorse", 1], ["nobody", 2]]
  # ----------------------------------------------------
  DAILY_INVITATION_LIMIT = 10

  Statuses = [:member, :manager, :suspended]

  delegate :name, :timezone, :to => :user

  belongs_to :user
  belongs_to :group, inverse_of: :memberships, counter_cache: true

  belongs_to :email, :class_name => "Email", :foreign_key => "primary_email"
  belongs_to :prof_photo, :class_name=>'ProfilePhoto', :foreign_key=>'prof_photo_id', optional: true
  belongs_to :pers_photo, :class_name=>'ProfilePhoto', :foreign_key=>'pers_photo_id', optional: true
  has_one    :membership_request
  has_many   :likes

  has_many   :subgroup_memberships, through: :user
  has_many   :custom_answers
  has_many   :custom_questions, through: :group
  alias_method :answers, :custom_answers
  alias_method :questions, :custom_questions
  alias_method :organization, :group

  # New OptIn table containing all GS3 user-subscriptions
  has_many :subscriptions, as: :subscriber, class_name: 'OptIn' # polymorphic: true, 
  # LEGACY: legacy Notification and NotificationSubscription are old/unused classes
  has_many :notifications, as: :subscriber
  has_many :notification_subscriptions, as: :subscriber, dependent: :destroy

  scope :active, -> { where(suspended: false) }
  # scope :active, -> { joins(:group).where("groups.blocked_at = ?", nil) }
  scope :in_group,    -> (group){ where(group: group) }
  
  scope :for_subgroup, -> (subgroup){ joins(:subgroup_memberships).merge( subgroup.memberships.active ) }

  scope :managers,    -> { where(manager: true) }
  scope :manager,     -> { where(manager: true, suspended: false) }
  scope :not_manager, -> { where("manager = ? OR suspended = ?", false, true) }
  scope :bouncing,    -> { joins(:email).merge(Email.bouncing) }
  scope :suspended,   -> { where(suspended: true) }

  scope :not_in_subgroup, -> (subgroup){ where("memberships.user_id NOT IN (SELECT subgroup_memberships.user_id FROM subgroup_memberships WHERE subgroup_memberships.subgroup_id = ?)", subgroup) }
  scope :not_notified_since, -> (time) {
    where("memberships.last_notification is null or memberships.last_notification < ?", time)
  }

  scope :blastable,   -> (sender) {
      sender = (' AND memberships.blast_updates = 1' unless Membership===sender and sender.manager?);
      joins(:email).where("memberships.suspended = 0 AND emails.bouncing_at IS NULL#{sender}")
  }

  # sorted_for_views Scope adds sorting that is used in a few places in views. Mostly in dropdown menus or 
  # User settings pages that list all of a user's memberships, where we want the current group at the top of the list
  # I use a calculated column called sort_groups which allows us to put the current group at the top of the
  # list, then also sort by group name, all in a single query. sweet
  # !! IMPORTANT: to explicitly include the field 'memberships.id' -- because for some odd reason this query will overwrite
  #               the membership.id with the group_id. I have no idea why but it does, it will return the Membership but the id
  #               is overwritten with the group_id unless you do this
  scope :sorted_for_views, -> (current_group) { 
    joins(:group) \
    .where(deleted_at: nil) \
    .select("*", "memberships.id", "(CASE WHEN memberships.group_id=#{current_group.id} THEN -1 ELSE 1 END) as sort_groups") \
    .order(:sort_groups, "groups.name")
  }

  validates_presence_of :user_id, :group_id, :email

  before_create :set_default_notification_schedule
  before_create :check_and_clean_deleted_membership
  after_destroy :destroy_submemberships
  after_create  :approve_pending_membership_request

  accepts_nested_attributes_for :custom_answers

  def self.to_csv(memberships, search='', filter_by='', group_name='')
    CSV.generate do |csv|
      csv << ["#{group_name}'s members"]
      csv << ['Search:', search]
      csv << ['Filter by:', filter_by]
      csv << []
      csv << ['First name', 'Last name', 'Email', 'Role', 'Joined on', 'Last online', 'Source']
      memberships.each do |membership|
        joined_at_date   = ApplicationController.helpers.show_date(membership.joined_at&.in_time_zone, :excel_xls_export)
        last_online_date = ApplicationController.helpers.show_date(membership.last_online&.in_time_zone, :excel_xls_export)

        csv << [membership.user&.first_name, membership.user&.last_name, membership.email&.email, membership.role, joined_at_date, last_online_date, membership.source_name ]
      end
    end
  end

  def user_name
    return "[deleted]" if user.nil?
    user.name
  end

  def replies
    Reply.where(group_id: self.group_id, user_id: self.user_id)
  end

  def topics
    Topic.where(group_id: self.group_id, user_id: self.user_id)
  end

  def blog_posts
    BlogPost.where(group_id: self.group_id, user_id: self.user_id)
  end

  def total_posts
    topics.count + replies.count + blog_posts.count
  end

  def rsvps
    Rsvp.joins(:event).where('events.group_id': self.group_id, 'rsvps.user_id': self.user_id)
  end

  def submemberships
    SubgroupMembership.where(user_id: user_id, group_id: group_id)
  end

  def subgroup_ids
    submemberships.pluck(:subgroup_id)
  end

  def wants_blast_from?(sender)
    #logger.warn "Sender is NIL in Membership.wants_blast_from?" if sender.nil?
    blast_updates? || sender.nil? || sender.manager?
  end

  # LEGACY: Is this used anywhere in GS3? I think we may only be using default_photo on the 
  # User class in GS3...do we use different profile photos for each membership?
  def default_photo
    group.default_profile_persona==1 ? pers_photo : prof_photo
  end

  def set_group_target(group)
    self.group = group
  end

  # ----------------------------------------------------------------------
  # Statuses
  # ----------------------------------------------------------------------
  def status
    active? ? 'active' : 'suspended'
  end
  def active?
    !suspended?
  end

  def member_status
    manager? ? 'manager' : 'member'
  end

  def role
    if suspended?
      "Suspended#{manager? ? ' (Manager)' : ''}"
    elsif manager?
      'Manager'
    else
      'Member'
    end
  end

  def source_name
    case source
      when 'joined'
        'Joined'
      when 'requested'
        'Requested'
      when 'invited', 'invited_with_link'
        'Invited'
      when 'sso'
        'SSO'
      else
        source&.capitalize
    end    
  end

  # ----------------------------------------------------------------------

  def joined_at; created_at; end

  # ----------------------------------------------------------------------
  # Custom Questions/Answers (also see the same relation in MembershipRequest)
  # ----------------------------------------------------------------------
  #This only deals with the *required* questions, which show up during the join processs
  def questions_and_answers
    @questions_and_answers ||= QuestionsAndAnswers.new(group.custom_questions.required, custom_answers)
  end

  def questions_and_answers=(attrs)
    questions_and_answers.answers = attrs[:answers]
  end

  def visible_subgroup_ids
    if defined?(@visible_subgroup_ids)
      @visible_subgroup_ids
    else
      @visible_subgroup_ids = group.visible_subgroup_ids | member_subgroup_ids
    end
  end

  def member_subgroup_ids(reload = false)
    if defined?(@member_subgroup_ids) && !reload
      @member_subgroup_ids
    else
      @member_subgroup_ids = submemberships.pluck(:subgroup_id)
    end
  end

  def managed_subgroup_ids
    if defined?(@managed_subgroup_ids)
      @managed_subgroup_ids
    else
      @managed_subgroup_ids = submemberships.manager.pluck(:subgroup_id)
    end
  end

  def can_view_subgroup?(subgroup)
    subgroup.nil? or visible_subgroup_ids.include?(subgroup.id)
  end

  def categorized_audit_ids_for_notification(categorized_audits, now)
    categorized_audits.keys.inject({}) do |acc, category|

      audits = categorized_audits[category].select do |audit|
        can_view_subgroup?(audit.subgroup) and can_be_notified_for?(audit, now)
      end

      acc[category] = audits.map(&:id) unless audits.empty?
      acc
    end
  end

  def can_be_notified_for?(audit, now = Time.current)
    (!audit.deleted_subgroup?) && (!audit.only_managers? || manager?) && (audit.created_at <= now.utc) &&
    (last_notification.nil? || audit.created_at > last_notification)
  end

  def notification_schedule
    self[:notification_schedule] || group.default_notification_schedule
  end

  def notification_schedule_label
    Audit::RECENT_ACTIVITY_UPDATE_SCHEDULE_LABELS[notification_schedule].to_s.titleize
  end

  def last_notified_before?(time)
    last_notification.nil? or last_notification < time
  end

  def scheduled?(now)
    schedule = notification_schedule

    case schedule
      when Audit::RECENT_ACTIVITY_UPDATE_SCHEDULE_OPTIONS[:'Once a day']
        [1, 2, 3, 4, 5].include?(now.wday)
      when Audit::RECENT_ACTIVITY_UPDATE_SCHEDULE_OPTIONS[:'Twice a week']
        (now.wday == 2 or now.wday == 4) and last_notified_before?(now - 2.days)
      when Audit::RECENT_ACTIVITY_UPDATE_SCHEDULE_OPTIONS[:'Once a week']
        now.wday == 3 and last_notified_before?(now - 6.days)
      when Audit::RECENT_ACTIVITY_UPDATE_SCHEDULE_OPTIONS[:'Twice a month']
        now.wday == 3 and last_notified_before?(now - 13.days)
      else
        false
    end
  end
private
  #------------------------------------------------------------------------
  # Callbacks
  #------------------------------------------------------------------------
  def set_default_notification_schedule
    self.notification_schedule = group.default_notification_schedule
  end

  def destroy_submemberships
    group.subgroups.each do |subgroup|
      if submembership = user.membership_for(subgroup)
        submembership.destroy
        SsoLogger.warn "SSO Submembership DELETED (Membership AfterDestroy): group=#{group.subdomain} | subgroup=#{submembership.subgroup.identifier} | user=#{user.id}", {klass: self, method: "destroy_submemberships"}
      end
    end
  end

  def approve_pending_membership_request
    pending_mr = MembershipRequest.find_by(user_id: self.user_id, group_id: self.group_id)
    if pending_mr.present?
      pending_mr.approved= true
      pending_mr.reviewed_at = Time.current
      pending_mr.reviewed_by = self.user_id
      pending_mr.save
    end
  end

  ##Note- this method completely delete soft deleted membership so that new membership created with same email and group
  def check_and_clean_deleted_membership
    deleted_membership = group.memberships.only_deleted.find_by(primary_email: primary_email)
    if deleted_membership && deleted_membership.destroy
      deleted_membership.really_destroy!
    end
  end

end
