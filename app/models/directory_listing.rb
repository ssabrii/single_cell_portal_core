class DirectoryListing

	###
	#
	# DirectoryListing: object that holds metadata about groups of files in a specific location in a GCS bucket
	# Mainly used to supply blanket descriptions for all files at given location
	#
	###

	include Mongoid::Document
	include Mongoid::Timestamps
	include Rails.application.routes.url_helpers # for accessing download_file_path and download_private_file_path

	PRIMARY_DATA_TYPES = %w(fq fastq).freeze
	READ_PAIR_IDENTIFIERS = %w(_R1 _R2 _I1 _I2).freeze

	belongs_to :study

	field :name, type: String
	field :description, type: String
	field :file_type, type: String
	field :files, type: Array
	field :sync_status, type: Boolean, default: false

	validates_uniqueness_of :name, scope: [:study_id, :file_type]

	index({ name: 1, study_id: 1, file_type: 1 }, { unique: true, background: true })

	# check if a directory_listing has a file
	def has_file?(filename)
		!self.files.detect(filename).nil?
	end

	# helper to generate correct urls for downloading fastq files
	def download_path(file)
		if self.study.public?
			download_file_path(self.study.url_safe_name, filename: file)
		else
			download_private_file_path(self.study.url_safe_name, filename: file)
		end
	end

	# helper to render name appropriately for use in download modals
	def download_display_name
		if self.name == '/'
			self.name
		else
			'/' + self.name + '/'
		end
	end

	# guess at a possible sample name based on filename
	def possible_sample_name(filename)
		filename.split('/').last.split('.').first
	end

  # generate a gs-url to a file in the files list in the study's GCS bucket
  def gs_url(filename)
		if self.has_file?(filename)
			"gs://#{self.study.bucket_id}/#{filename}"
		end
	end

	# return sample name based on filename (everything to the left of _(R|I)(1|2) string in file basename)
  # will also transform periods into underscores as these are unallowed in FireCloud
	def self.sample_name(filename)
		basename = self.file_basename(filename)
		DirectoryListing::READ_PAIR_IDENTIFIERS.each do |identifier|
			index = basename.index(identifier)
			if index
				return basename[0..index - 1].gsub(/\./, '_')
			else
				next
			end
		end
		basename
	end

	def self.read_position(filename)
		DirectoryListing::READ_PAIR_IDENTIFIERS.each do |identifier|
			if filename.match(/#{identifier}/)
				return DirectoryListing::READ_PAIR_IDENTIFIERS.index(identifier)
			end
		end
		0 # in case no paring info is found, return 0 for first position
	end

	# method to return a mapping of samples and paired reads based on contents of a file list
	def self.sample_read_pairings(files)
		map = {}
		files.each do |file|
			sample = DirectoryListing.sample_name(file[:name])
			map[sample] ||= []
			# determine 'position' of read, i.e. 0-3 based on presence of read identifier in filename
			position = DirectoryListing.read_position(file[:name])
			map[sample][position] = file[:gs_url]
		end
		map
	end

	# create a mapping of file extensions and counts based on a list of input files from a google bucket
	# keys to map are the path at which groups of files are found, and values are key/value pairs of file
	# extensions and counts
	def self.create_extension_map(files, map={})
		files.map(&:name).each do |name|
			# don't use directories in extension map
			unless name.end_with?('/')
				path = self.get_folder_name(name)
				ext = self.file_extension(name)
				# don't store primary data filetypes in map as these are handled separately
				if !DirectoryListing::PRIMARY_DATA_TYPES.any? {|e| ext.include?(e)}
					if map[path].nil?
						map[path] = {"#{ext}" => 1}
					elsif map[path][ext].nil?
						map[path][ext] = 1
					else
						map[path][ext] += 1
					end
				end
			end
		end
		map
	end

	# helper to return file extension for a given filename
	def self.file_extension(filename)
		parts = filename.split('.')
		size = parts.size
		if parts[size - 2] == 'tar' && parts.last == 'gz'
			# handle tar.gz files first, returning '[ext].tar.gz'
			parts[(size - 3)..(size - 1)].join('.')
		elsif parts.last == 'gz'
			# if the file is a gzip archive, return '[ext].gz'
			parts[(size - 2)..(size - 1)].join('.')
		else
			parts.last
		end
	end

	# get basename of file (everything in front of extension)
	def self.file_basename(filename)
		# in case the file is in a directory in the bucket, trim off the directory name(s)
		actual_filename = filename.split('/').last
		actual_filename.chomp(".#{self.file_extension(actual_filename)}")
	end

	# get the 'folder' of a file in a bucket based on its pathname
	def self.get_folder_name(filepath)
		filepath.include?('/') ? filepath.split('/').first : '/'
	end

end