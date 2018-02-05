class UserAnnotationShare

  ###
  #
  # UserAnnotationShare: class holding share information about UserAnnotations (similar to StudyShare)
  #
  ###

  ###
  #
  # FIELD DEFINITIONS, VALIDATIONS & CALLBACKS
  #
  ###

	include Mongoid::Document
	include Mongoid::Timestamps

	belongs_to :user_annotation
  belongs_to :study

	field :email, type: String
	field :permission, type: String, default: 'View'

	validates_uniqueness_of :email, scope: :user_annotation_id

	index({ email: 1, user_annotation_id: 1 }, { unique: true, background: true })

	PERMISSION_TYPES = %w(Edit View)

	before_save					:clean_email
  before_create				:set_study_id
	after_create				:send_notification
	after_update				:check_updated_permissions

  # return all valid user annotations that are shared with a given user for a given cluster
  def self.scoped_user_annotations(user, cluster)
		shares = self.where(email: user.email).select {|a| a.cluster_group_id == cluster.id}
		shares.map(&:user_annotation).flatten.select {|ua| ua.valid_annotation?}
	end

  # return all valid user annotations for a given user (either all shares or scoped to a specific permission)
  def self.valid_user_annotations(user, permission=nil)
		shares = permission.nil? ? self.where(email: user.email).to_a : self.where(email: user.email, permission: permission).to_a
		shares.map(&:user_annotation).flatten.select {|ua| ua.valid_annotation?}
	end

	private

  ###
  #
  # SETTERS & CUSTOM CALLBACKS
  #
  ###

  def clean_email
		self.email = self.email.strip
	end

	# send an email to both annotation owner & share user notifying them of the share
	def send_notification
		SingleCellMailer.share_annotation_notification(self.user_annotation.user, self).deliver_now
	end

	# send an email to both study owner & share user notifying them of the share
	def check_updated_permissions
		if self.permission_changed?
			SingleCellMailer.share_annotation_notification(self.user_annotation.user, self).deliver_now
		end
	end

  # set the study id after creation
  def set_study_id
		self.study_id = self.user_annotation.study_id
	end
end