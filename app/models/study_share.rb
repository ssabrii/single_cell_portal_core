class StudyShare

  ###
  #
  # StudyShare: class to hold sharing information about studies.  Integrates with FireCloud workspace ACLs.
  #
  ###

  ###
  #
  # FIELD DEFINITIONS, VALIDATIONS & CALLBACKS
  #
  ###

	include Mongoid::Document
	include Mongoid::Timestamps

	belongs_to :study

	field :email, type: String
	field	:firecloud_workspace, type: String
	field	:firecloud_project, type: String
	field :permission, type: String, default: 'View'
  field :deliver_emails, type: Boolean, default: true

	validates_uniqueness_of :email, scope: :study_id

	index({ email: 1, study_id: 1 }, { unique: true, background: true })

	PERMISSION_TYPES = %w(Edit View Reviewer)
	FIRECLOUD_ACLS = ['WRITER', 'READER', 'NO ACCESS']
  PERMISSION_DESCRIPTIONS = [
      'This user will have read/write access to both this study and FireCloud workspace',
      'This user will have read access to both this study and FireCloud workspace (cannot edit)',
      'This user will only have read access to this study (cannot download data or view FireCloud workspace)'
  ]

	# hashes that represent ACL mapping between the portal & firecloud and the inverse
	FIRECLOUD_ACL_MAP = Hash[PERMISSION_TYPES.zip(FIRECLOUD_ACLS)]
	PORTAL_ACL_MAP = Hash[FIRECLOUD_ACLS.zip(PERMISSION_TYPES)]
  PERMISSION_DESCRIPTION_MAP = Hash[PERMISSION_TYPES.zip(PERMISSION_DESCRIPTIONS)]

	before_validation		:set_firecloud_workspace_and_project, on: :create
	before_save					:clean_email
	after_create				:send_notification
	after_update				:check_updated_permissions
	validate						:set_firecloud_acl, on: [:create, :update]
	before_destroy			:revoke_firecloud_acl

	# use the share email as an ID for forms
	def email_as_id
		self.email.gsub(/[@\.]/, '-')
	end

	private

  ###
  #
  # SETTERS & CUSTOM VALIDATIONS/CALLBACKS
  #
  ###

	def set_firecloud_workspace_and_project
		self.firecloud_workspace = self.study.firecloud_workspace
		self.firecloud_project = self.study.firecloud_project
	end

	def clean_email
		self.email = self.email.strip
	end

	# send an email to both study owner & share user notifying them of the share
	def send_notification
		SingleCellMailer.share_notification(self.study.user, self).deliver_now
	end

	# send an email to both study owner & share user notifying them of the share
	def check_updated_permissions
		if self.permission_changed?
			SingleCellMailer.share_notification(self.study.user, self).deliver_now
		end
	end

	# set FireCloud workspace ACLs on share saving, raise validation error on fail and halt execution
	def set_firecloud_acl
		# in case of new study creation, automatically return true as we will create shares after study workspace is created
		if self.new_record? && self.study.new_record?
			return true
		else
			# do not set ACLs for Reviewer shares (they have no FireCloud permissions)
			unless self.permission == 'Reviewer'
				# set acls only if a new share or if the permission has changed
				if (self.new_record? && !self.study.new_record?) || (!self.new_record? && self.permission_changed?)
					Rails.logger.info "#{Time.now}: Creating FireCloud ACLs for study #{self.study.name} - share #{self.email}, permission: #{self.permission}"
					begin
						acl = Study.firecloud_client.create_workspace_acl(self.email, FIRECLOUD_ACL_MAP[self.permission])
						Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.study.firecloud_workspace, acl)
					rescue RuntimeError => e
						errors.add(:base, "Could not create a share for #{self.email} to workspace #{self.firecloud_workspace} due to: #{e.message}")
						false
					end
				end
			end
		end
	end

	# revoke FireCloud workspace access on share deletion, will email owner on fail to manually remove sharing as we can't do a validation on destroy
	def revoke_firecloud_acl
		begin
			unless self.permission == 'Reviewer'
				acl = Study.firecloud_client.create_workspace_acl(self.email, 'NO ACCESS')
				Study.firecloud_client.update_workspace_acl(self.firecloud_project, self.firecloud_workspace, acl)
			end
		rescue RuntimeError => e
			Rails.logger.error "#{Time.now}: Could not remove share for #{self.email} to workspace #{self.firecloud_workspace} due to: #{e.message}"
			SingleCellMailer.share_delete_fail(self.study, self.email).deliver_now
		end
	end
end