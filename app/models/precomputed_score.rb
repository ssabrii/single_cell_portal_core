class PrecomputedScore

  ###
  #
  # PrecomputedScore: gene-list based class that holds key/value pairs of genes and gene expression scores as well as cluster labels
  #
  ###

	include Mongoid::Document

	belongs_to :study
	belongs_to :study_file

	field :name, type: String
	field :clusters, type: Array
	field :gene_scores, type: Array

	index({ study_id: 1 }, { unique: false, background: true })

  validates_uniqueness_of :name, scope: :study_id
  validates_presence_of :name, :clusters, :gene_scores

	def gene_list
		self.gene_scores.map(&:keys).flatten
	end
end