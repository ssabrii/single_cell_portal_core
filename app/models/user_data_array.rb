class UserDataArray

  ###
  #
  # UserDataArray: child class of ClusterGroup & UserAnnotation, stores linear arrays of data (x/y/z coordinates, or annotation values)
  # Data is held separate from DataArray collection unless study owner 'publishes' annotations back to source data, in which case
  # the UserAnnotation is destroyed.
  #
  ###

  include Mongoid::Document
  field :name, type: String
  field :values, type: Array
  field :cluster_name, type: String
  field :array_type, type: String
  field :array_index, type: Integer
  field :subsample_threshold, type: Integer
  field :subsample_annotation, type: String

  belongs_to :user
  belongs_to :cluster_group
  belongs_to :study
  belongs_to :user_annotation


  index({ name: 1, user_annotation_id: 1, user_id: 1, study_id: 1, cluster_group_id: 1, cluster_name: 1,
          array_type: 1, array_index: 1, subsample_threshold: 1, subsample_annotation: 1 },
        { unique: true, name: 'unique_user_data_arrays_index', background: true })

  index({ user_id: 1 }, { unique: false, background: true })
  index({ study_id: 1, user_id: 1}, { unique: false, background: true })

  validates_presence_of :name, :user_id, :cluster_name, :array_type, :array_index, :values
  validates_uniqueness_of :name, scope: [:user_annotation_id, :study_id, :user_id, :cluster_name, :cluster_group_id, :array_type, :array_index, :subsample_threshold, :subsample_annotation]


  # maximum number of entries for values array (to avoid MongoDB max document size problems)
  MAX_ENTRIES = 100000

end
