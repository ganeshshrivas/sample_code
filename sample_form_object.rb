class Groups::Settings::ProfileQuestionsForm
  include ActiveModel::Model

  attr_accessor :group, :profile_questions, :required_fields, :updated_by

  attr_accessor :company, :title,:phone,:postal_code

  VALID_FIELD_OPTIONS = [:not_asked, :optional, :required].freeze

  validates_inclusion_of  :company,
                          :title,
                          :phone,
                          :postal_code,
                          in: VALID_FIELD_OPTIONS, allow_nil: false


  validate :group_is_valid

  def initialize(group:, profile_questions: {}, required_fields: {}, updated_by: nil)
    @updated_by = updated_by
    @group = group
    @profile_questions = profile_questions
    @required_fields = required_fields
    if required_fields.blank?
      # set attributes from the group - this will populate the form fields if the group is persisted
      @company     = group.user_required_fields[:company]
      @title       = group.user_required_fields[:title]
      @phone       = group.user_required_fields[:phone]
      @postal_code = group.user_required_fields[:postal_code]
    else
      # if we are given params set attributes using them
      @company      = @required_fields[:company].to_sym if @required_fields[:company]
      @title        = @required_fields[:title].to_sym if @required_fields[:title]
      @phone        = @required_fields[:phone].to_sym if @required_fields[:phone]
      @postal_code  = @required_fields[:postal_code].to_sym if @required_fields[:postal_code]
    end
  end

  def submit
    return false if invalid?
    ActiveRecord::Base.transaction do
      create_group_profile_questions(profile_questions)
      @group.user_required_fields = group_user_required_fields_params
      @group.save!
    end
    return true
  rescue Exception => e
      # Handle exception that caused the transaction to fail
      # e.message and e.cause.message can be helpful
      # User default validate to add errors custom questions and answers
      errors.add(:base, e.message)
      return false
  end



 private
  # validating group 
  def group_is_valid
    errors.add(:base, @group.errors.full_messages.join("<br/>")) if group.invalid?
  end

  def create_group_profile_questions(attributes)
    return unless attributes[:custom_questions_attributes].present?
    attributes[:custom_questions_attributes].each do |i, question_params|
      question = group.custom_questions.find_by_id question_params[:id]

      if question && question_params["_destroy"] == "true"
        question.destroy
      elsif question && question_params["_destroy"] == "false"
        question.update(question_params.except("id", "_destroy"))
      else
        group.custom_questions.create(question_params.except("_destroy").merge(updated_by: updated_by))
      end
    end
  end

  # Group user required fieds params
  def group_user_required_fields_params
    { company: @company, title: @title, phone: @phone, postal_code: @postal_code }
  end
  
end