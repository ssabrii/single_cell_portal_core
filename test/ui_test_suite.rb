require 'rubygems'
require 'test/unit'
require 'selenium-webdriver'
require File.expand_path('ui_test_helper.rb', 'test')

# UI regression suite that exercises functionality through simulating user interactions via Webdriver
#
# REQUIREMENTS
#
# This test suite must be run from outside of Docker (i.e. your host machine) as Docker cannot access localhost on your machine when running in linked container mode.
# Therefore, the following languages/packages must be installed on your host:
#
# 1. RVM (or equivalent Ruby language management system)
# 2. Ruby >= 2.3 (currently, 2.3.1 is the version running inside the container)
# 3. Gems: rubygems, test-unit, selenium-webdriver (see Gemfile.lock for version requirements)
# 4. Google Chrome
# 5. Chromedriver (https://sites.google.com/a/chromium.org/chromedriver/); make sure the verison you install works with your version of chrome
# 6. Register for FireCloud (https://portal.firecloud.org) for both Google accounts (needed for auth & sharing acls)
# 7. The 'test email account' (see below) must be configured as a portal admin.  See 'ADMIN USER ACCOUNTS' in README.rdoc for more information.

# USAGE
#
# To run the test suite:
#
# ruby test/ui_test_suite.rb [-n /pattern/] [--ignore-name /pattern/] -- -c=/path/to/chromedriver -e=testing.email@gmail.com -p='testing_email_password' -s=sharing.email@gmail.com -P='sharing_email_password' -o=order -d=/path/to/downloads -u=portal_url -E=environment -r=random_seed -v
#
# ui_test_suite.rb takes up to 12 arguments (4 are required):
# 1. path to your Chromedriver binary (passed with -c=)
# 2. path to your Chrome profile (passed with -C=): tests may fail to log in properly if you do not load the default chrome profile due to Google captchas
# 3. test email account (passed with -e=); REQUIRED. this must be a valid Google & FireCloud user and also configured as an 'admin' account in the portal
# 4. test email account password (passed with -p) REQUIRED. NOTE: you must quote the password to ensure it is passed correctly
# 5. share email account (passed with -s=); REQUIRED. this must be a valid Google & FireCloud user
# 6. share email account password (passed with -P) REQUIRED. NOTE: you must quote the password to ensure it is passed correctly
# 7. test order (passed with -o=); defaults to defined order (can be alphabetic or random, but random will most likely fail horribly
# 8. download directory (passed with -d=); place where files are downloaded on your OS, defaults to standard OSX location (/Users/`whoami`/Downloads)
# 9. portal url (passed with -u=); url to point tests at, defaults to https://localhost/single_cell
# 10. environment (passed with -E=); Rails environment that the target instance is running in.  Needed for constructing certain URLs
# 11. random seed (passed with -r=); random seed to use when running tests (will be needed if you're running front end tests against previously created studies from test suite)
# 12. verbose (passed with -v); run tests in verbose mode, will print extra logging messages where appropriate
#
# IMPORTANT: if you do not use -- before the argument list and give the appropriate flag (with =), it is processed as a Test::Unit flag and ignored, and likely may
# cause the suite to fail to launch.
#
# Tests are named using a tag-based system so that they can be run in smaller groups to only cover specific portions of site functionality.
# They can be run singly or in groups by passing -n /pattern/ before the -- on the command line.  This will run any tests that match
# the given regular expression.  You can run all 'front-end' and 'admin' tests this way (although front-end tests require the tests studies to have been created already)

# For instance, to run all the tests that cover user annotations:
#
# ruby ui_test_suite.rb -n /user-annotation/ -- [rest of arguments]
#
# To run a single test by name, pass -n 'test: [name of test]', e.g -n 'test: front-end: view: study'
#
# Similarly, you can run all test but exclude some by using --ignore-name /pattern/.  Also, you can combine -n and --ignore-name to run all matching
# test, excluding those matched by ignore-name.
#
# NOTE: when running this test harness, it tends to perform better on an external monitor.  Webdriver is very sensitive to elements not
# being clickable, and the more screen area available, the better.



## INITIALIZATION & CONFIGURATION

# parse arguments and set global variables
parse_test_arguments(ARGV)

# print configuration
puts "Chromedriver Binary: #{$chromedriver_path}"
puts "Testing email: #{$test_email}"
puts "Sharing email: #{$share_email}"
puts "Download directory: #{$download_dir}"
puts "Portal URL: #{$portal_url}"
puts "Environment: #{$env}"
puts "Random Seed: #{$random_seed}"
puts "Verbose: #{$verbose}"

# make sure download & chromedriver paths exist and portal url is valid, otherwise kill tests before running and print usage
if !File.exists?($chromedriver_path)
	puts "No Chromedriver binary found at #{$chromedriver_path}"
	puts $usage
	exit(1)
elsif !Dir.exists?($download_dir)
	puts "No download directory found at #{$download_dir}"
	puts $usage
	exit(1)
elsif !$portal_url.start_with?('https://') || $portal_url[($portal_url.size - 12)..($portal_url.size - 1)] != '/single_cell'
	puts "Invalid portal url: #{$portal_url}; must begin with https:// and end with /single_cell"
	puts $usage
	exit(1)
end

class UiTestSuite < Test::Unit::TestCase
	self.test_order = $order

	# setup is called before every test is run, this instantiates the driver and configures waits and other variables needed
	def setup
		# disable the 'save your password' prompt
		caps = Selenium::WebDriver::Remote::Capabilities.chrome("chromeOptions" => {'prefs' => {'credentials_enable_service' => false}})
		options = Selenium::WebDriver::Chrome::Options.new
		options.add_argument('--enable-webgl-draft-extensions')
		options.add_argument('--incognito')
		@driver = Selenium::WebDriver::Driver.for :chrome, driver_path: $chromedriver_dir,
																							options: options, desired_capabilities: caps,
																							driver_opts: {log_path: '/tmp/webdriver.log'}
		@driver.manage.window.maximize
		@base_url = $portal_url
		@accept_next_alert = true
		@driver.manage.timeouts.implicit_wait = 15
		# only Google auth

		@genes = %w(Itm2a Sergef Chil5 Fam109a Dhx9 Ssu72 Olfr1018 Fam71e2 Eif2b2)
		@wait = Selenium::WebDriver::Wait.new(:timeout => 30)
		@test_data_path = File.expand_path(File.join(File.dirname(__FILE__), 'test_data')) + '/'
		@base_path = File.expand_path(File.join(File.dirname(__FILE__), '..'))
		puts "\n"
	end

	# called on completion of every test (whether it passes or fails)
	def teardown
		invalidate_google_session
		@driver.quit
	end

	###
	#
	# ADMIN & CONFIGURATION TESTS
	#
	###

	##
	## CREATE STUDIES
	## These tests create the main studies used in downstream tests
	##

	# create basic test study
	test 'admin: create-study: sharing: configurations: validation: download: user-annotation: workflows: user-profiles: public' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		# log in as user #1
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("Test Study #{$random_seed}")
		public = study_form.find_element(:id, 'study_public')
		public.send_keys('Yes')
		# add a share
		share = @driver.find_element(:id, 'add-study-share')
		@wait.until {share.displayed?}
		share.click
		share_email = study_form.find_element(:class, 'share-email')
		share_email.send_keys($share_email)
		share_permission = study_form.find_element(:class, 'share-permission')
		share_permission.send_keys('Edit')
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')

		# upload a second expression file
		new_expression = @driver.find_element(:class, 'add-expression')
		new_expression.click
		scroll_to(:bottom)
		upload_expression_2 = @driver.find_element(:id, 'upload-expression')
		upload_expression_2.send_keys(@test_data_path + 'expression_matrix_example_2.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload metadata
		wait_for_render(:id, 'metadata_form')
		upload_metadata = @driver.find_element(:id, 'upload-metadata')
		upload_metadata.send_keys(@test_data_path + 'metadata_example2.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload cluster
		cluster_form_1 = @driver.find_element(:class, 'initialize_ordinations_form')
		cluster_name = cluster_form_1.find_element(:class, 'filename')
		cluster_name.send_keys('Test Cluster 1')
		upload_cluster = cluster_form_1.find_element(:class, 'upload-clusters')
		upload_cluster.send_keys(@test_data_path + 'cluster_example_2.txt')
		wait_for_render(:id, 'start-file-upload')
		# add labels and axis ranges
		cluster_form_1.find_element(:id, :study_file_x_axis_min).send_key(-100)
		cluster_form_1.find_element(:id, :study_file_x_axis_max).send_key(100)
		cluster_form_1.find_element(:id, :study_file_y_axis_min).send_key(-75)
		cluster_form_1.find_element(:id, :study_file_y_axis_max).send_key(75)
		cluster_form_1.find_element(:id, :study_file_z_axis_min).send_key(-125)
		cluster_form_1.find_element(:id, :study_file_z_axis_max).send_key(125)
		cluster_form_1.find_element(:id, :study_file_x_axis_label).send_key('X Axis')
		cluster_form_1.find_element(:id, :study_file_y_axis_label).send_key('Y Axis')
		cluster_form_1.find_element(:id, :study_file_z_axis_label).send_key('Z Axis')
		# perform upload
		upload_btn = cluster_form_1.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload a second cluster
		new_cluster = @driver.find_element(:class, 'add-cluster')
		new_cluster.click
		scroll_to(:bottom)
		# will be second instance since there are two forms
		cluster_form_2 = @driver.find_element(:class, 'new-cluster-form')
		cluster_name_2 = cluster_form_2.find_element(:class, 'filename')
		cluster_name_2.send_keys('Test Cluster 2')
		upload_cluster_2 = cluster_form_2.find_element(:class, 'upload-clusters')
		upload_cluster_2.send_keys(@test_data_path + 'cluster_2_example_2.txt')
		wait_for_render(:id, 'start-file-upload')
		scroll_to(:bottom)
		upload_btn_2 = cluster_form_2.find_element(:id, 'start-file-upload')
		upload_btn_2.click
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload a coordinate labels file
		wait_for_render(:class, 'add-coordinate-labels')
		add_coords_btn = @driver.find_element(:class, 'add-coordinate-labels')
		add_coords_btn.click
		wait_for_render(:class, 'initialize_labels_form')
		coords_form = @driver.find_element(:class, 'initialize_labels_form')
		cluster_select = coords_form.find_element(:id, 'study_file_options_cluster_group_id')
		cluster_select.send_keys('Test Cluster 1')
		upload_coords = coords_form.find_element(:class, 'upload-labels')
		upload_coords.send_keys(@test_data_path + 'coordinate_labels_1.txt')
		upload_btn = coords_form.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload right fastq
		wait_for_render(:class, 'initialize_primary_data_form')
		upload_fastq = @driver.find_element(:class, 'upload-fastq')
		upload_fastq.send_keys(@test_data_path + 'cell_1_R1_001.fastq.gz')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload left fastq
		add_fastq = @driver.find_element(:class, 'add-primary-data')
		add_fastq.click
		wait_for_render(:class, 'new-fastq-form')
		new_fastq_form = @driver.find_element(class: 'new-fastq-form')
		new_upload_fastq = new_fastq_form.find_element(:class, 'upload-fastq')
		new_upload_fastq.send_keys(@test_data_path + 'cell_1_I1_001.fastq.gz')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = new_fastq_form.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload marker gene list
		wait_for_render(:class, 'initialize_marker_genes_form')
		marker_form = @driver.find_element(:class, 'initialize_marker_genes_form')
		marker_file_name = marker_form.find_element(:id, 'study_file_name')
		marker_file_name.send_keys('Test Gene List')
		upload_markers = marker_form.find_element(:class, 'upload-marker-genes')
		upload_markers.send_keys(@test_data_path + 'marker_1_gene_list.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = marker_form.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload doc file
		wait_for_render(:class, 'initialize_misc_form')
		upload_doc = @driver.find_element(:class, 'upload-misc')
		upload_doc.send_keys(@test_data_path + 'table_1.xlsx')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')

		# change attributes on file to validate update function
		misc_form = @driver.find_element(:class, 'initialize_misc_form')
		desc_field = misc_form.find_element(:id, 'study_file_description')
		desc_field.send_keys('Supplementary table')
		save_btn = misc_form.find_element(:class, 'save-study-file')
		save_btn.click
		wait_for_modal_open('study-file-notices')
		close_modal('study-file-notices')

		# now check newly created study info page
		studies_path = @base_url + '/studies'
		@driver.get studies_path

		show_study = @driver.find_element(:class, "test-study-#{$random_seed}-show")
		show_study.click

		# verify that counts are correct, this will ensure that everything uploaded & parsed correctly
		cell_count = @driver.find_element(:id, 'cell-count').text.to_i
		gene_count = @driver.find_element(:id, 'gene-count').text.to_i
		cluster_count = @driver.find_element(:id, 'cluster-count').text.to_i
		gene_list_count = @driver.find_element(:id, 'precomputed-count').text.to_i
		metadata_count = @driver.find_element(:id, 'metadata-count').text.to_i
		cluster_annot_count = @driver.find_element(:id, 'cluster-annotation-count').text.to_i
		study_file_count = @driver.find_element(:id, 'study-file-count').text.to_i
		primary_data_count = @driver.find_element(:id, 'primary-data-count').text.to_i
		share_count = @driver.find_element(:id, 'share-count').text.to_i

		assert cell_count == 30, "did not find correct number of cells, expected 30 but found #{cell_count}"
		assert gene_count == 19, "did not find correct number of genes, expected 19 but found #{gene_count}"
		assert cluster_count == 2, "did not find correct number of clusters, expected 2 but found #{cluster_count}"
		assert gene_list_count == 1, "did not find correct number of gene lists, expected 1 but found #{gene_list_count}"
		assert metadata_count == 3, "did not find correct number of metadata objects, expected 3 but found #{metadata_count}"
		assert cluster_annot_count == 3, "did not find correct number of cluster annotations, expected 2 but found #{cluster_annot_count}"
		assert study_file_count == 8, "did not find correct number of study files, expected 8 but found #{study_file_count}"
		assert primary_data_count == 2, "did not find correct number of primary data files, expected 2 but found #{primary_data_count}"
		assert share_count == 1, "did not find correct number of study shares, expected 1 but found #{share_count}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# create a 2d scatter study for use in user annotation testing
	test 'admin: create-study: user-annotation: 2d' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		# log in as user #1
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("twod Study #{$random_seed}")
		public = study_form.find_element(:id, 'study_public')
		public.send_keys('Yes')
		# add a share
		share = @driver.find_element(:id, 'add-study-share')
		@wait.until {share.displayed?}
		share.click
		share_email = study_form.find_element(:class, 'share-email')
		share_email.send_keys($share_email)
		share_permission = study_form.find_element(:class, 'share-permission')
		share_permission.send_keys('Edit')
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload metadata
		wait_for_render(:id, 'metadata_form')
		upload_metadata = @driver.find_element(:id, 'upload-metadata')
		upload_metadata.send_keys(@test_data_path + 'metadata_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload cluster
		cluster_form_1 = @driver.find_element(:class, 'initialize_ordinations_form')
		cluster_name = cluster_form_1.find_element(:class, 'filename')
		cluster_name.send_keys('Test Cluster 1')
		upload_cluster = cluster_form_1.find_element(:class, 'upload-clusters')
		upload_cluster.send_keys(@test_data_path + 'cluster_2d_example.txt')
		wait_for_render(:id, 'start-file-upload')

		# perform upload
		upload_btn = cluster_form_1.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload marker gene list
		scroll_to(:top)
		gene_list_tab = @driver.find_element(:id, 'initialize_marker_genes_form_nav')
		gene_list_tab.click
		marker_form = @driver.find_element(:class, 'initialize_marker_genes_form')
		marker_file_name = marker_form.find_element(:id, 'study_file_name')
		marker_file_name.send_keys('Test Gene List')
		upload_markers = marker_form.find_element(:class, 'upload-marker-genes')
		upload_markers.send_keys(@test_data_path + 'marker_1_gene_list.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = marker_form.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# confirm all files uploaded
		studies_path = @base_url + '/studies'
		@driver.get studies_path

		study_file_count = @driver.find_element(:id, "twod-study-#{$random_seed}-study-file-count").text.to_i
		assert study_file_count == 4, "did not find correct number of files, expected 4 but found #{study_file_count}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# create private study for testing visibility/edit restrictions
	test 'admin: create-study: sharing: download: private' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("Private Study #{$random_seed}")
		public = study_form.find_element(:id, 'study_public')
		public.send_keys('No')
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload metadata
		wait_for_render(:id, 'metadata_form')
		upload_metadata = @driver.find_element(:id, 'upload-metadata')
		upload_metadata.send_keys(@test_data_path + 'metadata_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload cluster
		cluster_form_1 = @driver.find_element(:class, 'initialize_ordinations_form')
		cluster_name = cluster_form_1.find_element(:class, 'filename')
		cluster_name.send_keys('Test Cluster 1')
		upload_cluster = cluster_form_1.find_element(:class, 'upload-clusters')
		upload_cluster.send_keys(@test_data_path + 'cluster_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload marker gene list
		scroll_to(:top)
		gene_list_tab = @driver.find_element(:id, 'initialize_marker_genes_form_nav')
		gene_list_tab.click
		marker_form = @driver.find_element(:class, 'initialize_marker_genes_form')
		marker_file_name = marker_form.find_element(:id, 'study_file_name')
		marker_file_name.send_keys('Test Gene List')
		upload_markers = marker_form.find_element(:class, 'upload-marker-genes')
		upload_markers.send_keys(@test_data_path + 'marker_1_gene_list.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = marker_form.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# add misc file
		add_misc = @driver.find_element(:class, 'add-misc')
		add_misc.click
		new_misc_form = @driver.find_element(:class, 'new-misc-form')
		upload_doc = new_misc_form.find_element(:class, 'upload-misc')
		upload_doc.send_keys(@test_data_path + 'README.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# text gzip parsing of expression matrices
	test 'admin: create-study: gzip expression matrix' do
		puts "Test method: #{self.method_name}"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("Gzip Parse #{$random_seed}")
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload bad expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example_gzipped.txt.gz')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# verify parse completed
		studies_path = @base_url + '/studies'
		@driver.get studies_path
		wait_until_page_loads(studies_path)
		study_file_count = @driver.find_element(:id, "gzip-parse-#{$random_seed}-study-file-count")
		assert study_file_count.text == '1', "found incorrect number of study files; expected 1 and found #{study_file_count.text}"
		puts "Test method: #{self.method_name} successful!"
	end

	##
	## STUDY VALIDATION
	## Validate newly created studies and test various validations and privacy restrictions
	##

	# verify that recently created study uploaded to firecloud
	test 'admin: create-study: verify firecloud workspace' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		show_study = @driver.find_element(:class, "test-study-#{$random_seed}-show")
		show_study.click

		# verify firecloud workspace creation
		firecloud_link = @driver.find_element(:id, 'firecloud-link')
		firecloud_url = "https://portal.firecloud.org/#workspaces/single-cell-portal/#{$env}-test-study-#{$random_seed}"
		firecloud_link.click
		@driver.switch_to.window(@driver.window_handles.last)
		completed = @driver.find_elements(:class, 'fa-check-circle')
		assert completed.size >= 1, 'did not provision workspace properly'
		assert @driver.current_url == firecloud_url, 'did not open firecloud workspace'

		# verify gcs bucket and uploads
		@driver.switch_to.window(@driver.window_handles.first)
		gcs_link = @driver.find_element(:id, 'gcs-link')
		gcs_link.click
		@driver.switch_to.window(@driver.window_handles.last)
		table = @driver.find_element(:id, 'p6n-storage-objects-table')
		table_body = table.find_element(:tag_name, 'tbody')
		files = table_body.find_elements(:tag_name, 'tr')
		assert files.size == 10, "did not find correct number of files, expected 10 but found #{files.size}"
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test to verify deleting files removes them from gcs buckets
	test 'admin: create-study: delete study file' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		add_files = @driver.find_element(:class, "test-study-#{$random_seed}-upload")
		add_files.click
		misc_tab = @driver.find_element(:id, 'initialize_misc_form_nav')
		misc_tab.click

		# test abort functionality first
		add_misc = @driver.find_element(:class, 'add-misc')
		add_misc.click
		new_misc_form = @driver.find_element(:class, 'new-misc-form')
		upload_doc = new_misc_form.find_element(:class, 'upload-misc')
		upload_doc.send_keys(@test_data_path + 'README.txt')
		wait_for_render(:id, 'start-file-upload')
		cancel = @driver.find_element(:class, 'cancel')
		cancel.click
		sleep(3)
		close_modal('study-file-notices')

		# delete file from test study
		form = @driver.find_element(:class, 'initialize_misc_form')
		delete = form.find_element(:class, 'delete-file')
		delete.click
		accept_alert

		# wait a few seconds to allow delete call to propogate all the way to FireCloud after confirmation modal
		close_modal('study-file-notices')
		sleep(3)

		@driver.get path
		files = @driver.find_element(:id, "test-study-#{$random_seed}-study-file-count")
		assert files.text == '9', "did not find correct number of files, expected 9 but found #{files.text}"

		# verify deletion in google
		show_study = @driver.find_element(:class, "test-study-#{$random_seed}-show")
		show_study.click
		gcs_link = @driver.find_element(:id, 'gcs-link')
		gcs_link.click
		@driver.switch_to.window(@driver.window_handles.last)
		table = @driver.find_element(:id, 'p6n-storage-objects-table')
		table_body = table.find_element(:tag_name, 'tbody')
		files = table_body.find_elements(:tag_name, 'tr')
		assert files.size == 9, "did not find correct number of files, expected 9 but found #{files.size}"
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test embargo functionality
	test 'admin: create-study: embargo' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("Embargo Study #{$random_seed}")
		embargo_date = (Date.today + 1).to_s
		study_form.find_element(:id, 'study_embargo').send_keys(embargo_date)

		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')

		# verify user can still download data
		embargo_url = @base_url + "/study/embargo-study-#{$random_seed}"
		@driver.get embargo_url
		@wait.until {element_present?(:id, 'study-download')}
		open_ui_tab('study-download')
		i = 0
		link_present = element_present?(:class, 'dl-link')
		while !link_present
			sleep 1
			@driver.get embargo_url
			@wait.until {element_present?(:id, 'study-download')}
			open_ui_tab('study-download')
			link_present = element_present?(:class, 'dl-link')
			i += 1
		end
		download_links = @driver.find_elements(:class, 'dl-link')
		assert download_links.size == 1, "did not find correct number of download links, expected 1 but found #{download_links.size}"

		# logout
		logout_from_portal

		# login as share user
		login_link = @driver.find_element(:id, 'login-nav')
		login_link.click
		login_as_other($share_email, $share_email_password)

		# now assert download links do not load
		@driver.get embargo_url
		@wait.until {element_present?(:id, 'study-download')}
		open_ui_tab('study-download')
		embargo_links = @driver.find_elements(:class, 'embargoed-file')
		assert embargo_links.size == 1, "did not find correct number of embargo links, expected 1 but found #{embargo_links.size}"

		# make sure embargo redirect is in place
		data_url = @base_url + "/data/public/embargo-study-#{$random_seed}?filename=expression_matrix_example.txt"
		@driver.get data_url
		wait_for_modal_open('message_modal')
		alert_text = @driver.find_element(:id, 'alert-content').text
		expected_alert = "You may not download any data from this study until #{(Date.today + 1).strftime("%B %-d, %Y")}."
		assert alert_text == expected_alert, "did not find correct alert, expected '#{expected_alert}' but found '#{alert_text}'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# negative tests to check file parsing & validation
	# email delivery is disabled in development, so this just ensures that bad files are removed after parse failure
	test 'admin: create-study: file validations' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("Error Messaging Test Study #{$random_seed}")
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload bad expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example_bad.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')

		# upload an expression matrix in R export format (no value at 0,0 in matrix)
		new_expression = @driver.find_element(:class, 'add-expression')
		new_expression.click
		scroll_to(:bottom)
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'R_format_text.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')
		# assert that we cannot delete the newly uploaded file
		exp_form = @driver.find_elements(:class, 'initialize_expression_form').last
		delete_btn = exp_form.find_element(:class, 'disabled-delete')
		assert !delete_btn.nil?, 'Did not find disabled delete button for newly uploaded file'
		assert delete_btn['disabled'] == 'true', "Delete button is not correctly disabled, expected disabled == 'true' but found #{delete_btn['disabled']}"
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload bad metadata assignments
		wait_for_render(:id, 'metadata_form')
		upload_assignments = @driver.find_element(:id, 'upload-metadata')
		upload_assignments.send_keys(@test_data_path + 'metadata_bad.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')

		# upload bad cluster coordinates
		upload_clusters = @driver.find_element(:class, 'upload-clusters')
		upload_clusters.send_keys(@test_data_path + 'cluster_bad.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')

		# upload bad marker gene list
		scroll_to(:top)
		gene_list_tab = @driver.find_element(:id, 'initialize_marker_genes_form_nav')
		gene_list_tab.click
		marker_form = @driver.find_element(:class, 'initialize_marker_genes_form')
		marker_file_name = marker_form.find_element(:id, 'study_file_name')
		marker_file_name.send_keys('Test Gene List')
		upload_markers = @driver.find_element(:class, 'upload-marker-genes')
		upload_markers.send_keys(@test_data_path + 'marker_1_gene_list_bad.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close modal
		close_modal('upload-success-modal')
		# wait for a few seconds to allow parses to fail fully
		sleep(3)

		# assert parses all failed and delete study
		@driver.get(@base_url + '/studies')
		wait_until_page_loads(@base_url + '/studies')
		study_file_count = @driver.find_element(:id, "error-messaging-test-study-#{$random_seed}-study-file-count")
		assert study_file_count.text == '1', "found incorrect number of study files; expected 1 and found #{study_file_count.text}"
		@driver.find_element(:class, "error-messaging-test-study-#{$random_seed}-delete").click
		accept_alert
		close_modal('message_modal')
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# check visibility & edit restrictions as well as share access
	# will also verify FireCloud ACL settings on shares
	test 'admin: sharing: view and edit permission' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# check view visibility for unauthenticated users
		path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get path
		assert @driver.current_url == @base_url, 'did not redirect'
		assert element_present?(:id, 'message_modal'), 'did not find alert modal'
		close_modal('message_modal')

		# log in and get study ids for use later
		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')

		# send login info
		login($test_email, $test_email_password)

		# get path info
		edit = @driver.find_element(:class, "private-study-#{$random_seed}-edit")
		edit.click
		# wait a few seconds for page to load before getting url
		sleep(2)
		private_study_id = @driver.current_url.split('/')[5]
		@driver.get @base_url + '/studies'
		edit = @driver.find_element(:class, "test-study-#{$random_seed}-edit")
		edit.click
		# wait a few seconds for page to load before getting url
		sleep(2)
		share_study_id = @driver.current_url.split('/')[5]

		# logout
		logout_from_portal

		# login as share user
		login_link = @driver.find_element(:id, 'login-nav')
		login_link.click
		login_as_other($share_email, $share_email_password)

		# view study
		path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get path
		assert @driver.current_url == @base_url, 'did not redirect'
		assert element_present?(:id, 'message_modal'), 'did not find alert modal'
		close_modal('message_modal')
		# check public visibility when logged in
		path = @base_url + "/study/gzip-parse-#{$random_seed}"
		@driver.get path
		assert @driver.current_url == path, 'did not load public study without share'

		# edit study
		edit_path = @base_url + '/studies/' + private_study_id + '/edit'
		@driver.get edit_path
		assert @driver.current_url == @base_url + '/studies', 'did not redirect'
		assert element_present?(:id, 'message_modal'), 'did not find alert modal'
		close_modal('message_modal')

		# test share
		share_view_path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get share_view_path
		assert @driver.current_url == share_view_path, 'did not load share study view'
		share_edit_path = @base_url + '/studies/' + share_study_id + '/edit'
		@driver.get share_edit_path
		assert @driver.current_url == share_edit_path, 'did not load share study edit'

		# test uploading a file
		upload_path = @base_url + '/studies/' + share_study_id + '/upload'
		@driver.get upload_path
		misc_tab = @driver.find_element(:id, 'initialize_misc_form_nav')
		misc_tab.click

		upload_doc = @driver.find_element(:class, 'upload-misc')
		upload_doc.send_keys(@test_data_path + 'README.txt')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# verify upload has completed and is in FireCloud bucket
		@driver.get @base_url + '/studies/'
		file_count = @driver.find_element(:id, "test-study-#{$random_seed}-study-file-count")
		assert file_count.text == '10', "did not find correct number of files, expected 10 but found #{file_count.text}"
		show_study = @driver.find_element(:class, "test-study-#{$random_seed}-show")
		show_study.click
		gcs_link = @driver.find_element(:id, 'gcs-link')
		gcs_link.click
		@driver.switch_to.window(@driver.window_handles.last)
		table = @driver.find_element(:id, 'p6n-storage-objects-table')
		table_body = table.find_element(:tag_name, 'tbody')
		files = table_body.find_elements(:tag_name, 'tr')
		assert files.size == 10, "did not find correct number of files, expected 9 but found #{files.size}"
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test reviewer functionality
	test 'admin: sharing: reviewer permission' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		edit = @driver.find_element(:class, "private-study-#{$random_seed}-edit")
		edit.click
		wait_for_render(:class, 'study-form')
		study_form = @driver.find_element(:class, 'study-form')
		share = study_form.find_element(:id, 'add-study-share')
		@wait.until {share.displayed?}
		share.click
		share_email = study_form.find_element(:class, 'share-email')
		share_email.send_keys($share_email)
		share_permission = study_form.find_element(:class, 'share-permission')
		share_permission.send_keys('Reviewer')
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click
		close_modal('message_modal')
		# now confirm reviewer share
		logout_from_portal
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login_as_other($share_email, $share_email_password)
		# make sure study shows up in list of 'My Studies'
		path = @base_url + "/studies"
		@driver.get path
		wait_for_render(:id, 'studies')
		assert element_present?(:id, "private-study-#{$random_seed}-view-live-link"), "Did not find link to view private study"
		private_study_link = @driver.find_element(:id, "private-study-#{$random_seed}-view-live-link")
		private_study_link.click
		assert element_present?(:class, 'study-lead'), 'Did not correctly load study page'

		# make sure download tab is properly disabled and no files can be downloaded
		download_tab = @driver.find_element(:id, 'study-download-nav')
		assert download_tab['class'].include?('disabled'), "Download tab was not properly disabled: #{download_tab['class']}"
		# try bypassing download with a direct call to file we uploaded earlier
		direct_link = @base_url + "/data/public/private-study-#{$random_seed}?filename=expression_matrix_example.txt"
		@driver.get direct_link
		alert_content = @driver.find_element(:id, 'alert-content')
		assert alert_content.text == 'You do not have permission to perform that action.', 'download was not successfully blocked'

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## SYNCHRONIZATION TESTS
	## Validates that 'sync' functionality is working correctly (creating a study from an existing FireCloud workspace)
	##

	# this test depends on a workspace already existing in FireCloud called development-sync-test
	# if this study has been deleted, this test will fail until the workspace is re-created with at least
	# 3 default files for expression, metadata, one cluster, and one fastq file (using the test data from test/test_data)
	test 'admin: sync-study: bulk: existing workspace' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# create a new study using an existing workspace, also generate a random name to validate that workspace name
		# and study name can be different
		random_name = "Sync Test #{$random_seed}"
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys(random_name)
		study_form.find_element(:id, 'study_use_existing_workspace').send_keys('Yes')
		study_form.find_element(:id, 'study_firecloud_workspace').send_keys("development-sync-test-study")
		share = @driver.find_element(:id, 'add-study-share')
		@wait.until {share.displayed?}
		share.click
		share_email = study_form.find_element(:class, 'share-email')
		share_email.send_keys($share_email)

		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click
		@wait.until {element_present?(:id, 'unsynced-study-files')}
		close_modal('message_modal')

		# sync each file
		study_file_forms = @driver.find_elements(:class, 'unsynced-study-file')
		study_file_forms.each do |form|
			filename = form.find_element(:id, 'study_file_name')['value']
			file_type = form.find_element(:id, 'study_file_file_type')
			case filename
				when 'cluster_example.txt'
					file_type.send_keys('Cluster')
				when 'subfolder/expression_matrix_example.txt'
					file_type.send_keys('Expression Matrix')
				when 'metadata_example.txt'
					file_type.send_keys('Metadata')
				else
					file_type.send_keys('Other')
			end
			sync_button = form.find_element(:class, 'save-study-file')
			sync_button.click
			close_modal('sync-notice-modal')
		end

		# sync directory listings
		directory_forms = @driver.find_elements(:class, 'unsynced-directory-listing')
		directory_forms.each do |form|
			sync_button = form.find_element(:class, 'save-directory-listing')
			sync_button.click
			close_modal('sync-notice-modal')
		end

		# now assert that forms were re-rendered in synced data panel
		sync_panel = @driver.find_element(:id, 'synced-data-panel-toggle')
		sync_panel.click
		# wait a second for panel to open
		sleep(1)
		synced_files_div = @driver.find_element(:id, 'synced-study-files')
		synced_files = synced_files_div.find_elements(:tag_name, 'form')
		assert synced_files.size == study_file_forms.size, "did not find correct number of synced files, expected #{study_file_forms.size} but found #{synced_files.size}"

		synced_dirs_div = @driver.find_element(:id, 'synced-directory-listings')
		synced_dirs = synced_dirs_div.find_elements(:tag_name, 'form')
		assert synced_dirs.size == directory_forms.size, "did not find correct number of synced files, expected #{directory_forms.size} but found #{synced_dirs.size}"

		updated_files = {}
		# now use synced data forms to update entries and keep track of changes for comparison later
		synced_files.each do |sync_form|
			file_type = sync_form.find_element(:id, 'study_file_file_type')[:value]
			name = sync_form.find_element(:id, 'study_file_name')[:value]
			description = "Description for #{file_type}"
			description_field = sync_form.find_element(:id, 'study_file_description')
			description_field.send_keys(description)
			updated_files["#{sync_form[:id]}"] = {
					name: name,
					file_type: file_type,
					description: description,
					parsed: file_type != 'Other'
			}
			sync_button = sync_form.find_element(:class, 'save-study-file')
			sync_button.click
			close_modal('sync-notice-modal')
		end

		# update directory listings too
		updated_dirs = {}
		synced_dirs.each do |sync_form|
			name = sync_form.find_element(:id, 'directory_listing_name')[:value]
			description = "Description for #{name}"
			description_field = sync_form.find_element(:id, 'directory_listing_description')
			description_field.send_keys(description)
			updated_dirs["#{sync_form[:id]}"] = {
					description: description,
					file_type: sync_form.find_element(:id, 'directory_listing_file_type')[:value]
			}
			sync_button = sync_form.find_element(:class, 'save-directory-listing')
			sync_button.click
			close_modal('sync-notice-modal')
		end

		# lastly, check info page to make sure everything did in fact parse and complete
		studies_path = @base_url + '/studies'
		@driver.get studies_path
		wait_until_page_loads(studies_path)

		show_button = @driver.find_element(:class, "sync-test-#{$random_seed}-show")
		show_button.click
		@wait.until {element_present?(:id, 'info-panel')}

		# assert number of files using the count badges (faster than counting table rows)
		study_file_count = @driver.find_element(:id, 'study-file-count').text.to_i
		primary_data_count = @driver.find_element(:id, 'primary-data-count').text.to_i
		other_data_count = @driver.find_element(:id, 'other-data-count').text.to_i
		assert study_file_count == study_file_forms.size, "did not find correct number of study files, expected #{study_file_forms.size} but found #{study_file_count}"
		assert primary_data_count == 1, "did not find correct number of primary data files, expected 1 but found #{primary_data_count}"
		assert other_data_count == 19, "did not find correct number of other data files, expected 19 but found #{primary_data_count}"

		# make sure edits saved by going through updated list of synced files and comparing values
		updated_files.each do |id, values|
			study_file_table_row = @driver.find_element(:id, id)
			entry_name = study_file_table_row.find_element(:class, 'study-file-name').text
			entry_file_type = study_file_table_row.find_element(:class, 'study-file-file-type').text
			entry_description = study_file_table_row.find_element(:class, 'study-file-description').text
			entry_parsed = study_file_table_row.find_element(:class, 'study-file-parsed')['data-parsed'] == 'true'
			assert values[:name] == entry_name, "study file entry #{id} name incorrect, expected #{values[:name]} but found #{entry_name}"
			assert values[:file_type] == entry_file_type, "study file entry #{id} file type incorrect, expected #{values[:file_type]} but found #{entry_file_type}"
			assert values[:description] == entry_description, "study file entry #{id} description incorrect, expected #{values[:description]} but found #{entry_description}"
			assert values[:parsed] == entry_parsed, "study file entry #{id} parse incorrect, expected #{values[:parsed]} but found #{entry_parsed}"
		end

		# now check directory listings datatables - we only need to match the first found row as all rows will have identical descriptions
		updated_dirs.each_value do |values|
			directory_listing_row = @driver.find_element(:class, values[:file_type] + '-entry')
			found_description = directory_listing_row.find_element(:class, 'dl-description')
			assert values[:description] == found_description.text, "directory listing description incorrect, expected #{values[:description]} but found #{found_description.text}"
		end

		# assert share was added
		share_email_id = 'study-share-' + $share_email.gsub(/[@.]/, '-')
		assert element_present?(:id, share_email_id), 'did not find proper share entry'
		share_row = @driver.find_element(:id, share_email_id)
		shared_email = share_row.find_element(:class, 'share-email').text
		assert shared_email == $share_email, "did not find correct email for share, expected #{$share_email} but found #{shared_email}"
		shared_permission = share_row.find_element(:class, 'share-permission').text
		assert shared_permission == 'View', "did not find correct share permissions, expected View but found #{shared_permission}"

		# make sure parsing succeeded
		sync_study_path = @base_url + "/study/sync-test-#{$random_seed}"
		@driver.get(sync_study_path)
		wait_until_page_loads(sync_study_path)
		open_ui_tab('study-visualize')

		assert element_present?(:class, 'study-lead'), 'could not find study title'
		assert element_present?(:id, 'cluster-plot'), 'could not find study cluster plot'

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert rendered, "cluster plot did not finish rendering, expected true but found #{rendered}"

		# search for a gene
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# now test removing items
		@driver.get(@base_url + '/studies')
		sync_button_class = random_name.split.map(&:downcase).join('-') + '-sync'
		sync_button = @driver.find_element(:class, sync_button_class)
		sync_button.click
		@wait.until {element_present?(:id, 'synced-study-files')}

		sync_panel = @driver.find_element(:id, 'synced-data-panel-toggle')
		sync_panel.click
		sleep(1)
		synced_files = @driver.find_elements(:class, 'synced-study-file')
		synced_directory_listing = @driver.find_element(:class, 'synced-directory-listing')

		# delete random file
		file_to_delete = synced_files.sample
		delete_file_btn = file_to_delete.find_element(:class, 'delete-study-file')
		delete_file_btn.click
		accept_alert
		close_modal('sync-notice-modal')

		# delete directory listing
		delete_dir_btn = synced_directory_listing.find_element(:class, 'delete-directory-listing')
		delete_dir_btn.click
		accept_alert
		close_modal('sync-notice-modal')
		# give DelayedJob one second to fire the DeleteQueueJob to remove the deleted entries
		sleep(1)

		# confirm files were removed
		@driver.get studies_path
		wait_until_page_loads(studies_path)
		study_file_count = @driver.find_element(:id, "sync-test-#{$random_seed}-study-file-count").text.to_i
		assert study_file_count == 4, "did not remove files, expected 4 but found #{study_file_count}"

		# remove share and resync
		edit_button = @driver.find_element(:class, "sync-test-#{$random_seed}-edit")
		edit_button.click
		wait_for_render(:class, 'study-share-form')
		# we need an extra sleep here to allow the javascript handlers to attach so that the remove_nested_fields event will fire
		sleep(0.5)
		share_id = $share_email.gsub(/[@\.]/, '-') + '-share-form'
		share_form = @driver.find_element(:id, share_id)
		remove_share = share_form.find_element(:class, 'remove_nested_fields')
		remove_share.click
		accept_alert
		# let the form remove from the page
		sleep (0.25)
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click
		close_modal('message_modal')
		sync_button = @driver.find_element(:class, "sync-test-#{$random_seed}-sync")
		sync_button.click
		wait_for_render(:id, 'synced-data-panel-toggle')

		# now confirm share was removed at FireCloud level
		logout_from_portal

		# now login as share user and check workspace
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login_as_other($share_email, $share_email_password)
		firecloud_workspace = "https://portal.firecloud.org/#workspaces/single-cell-portal/sync-test-#{$random_seed}"
		@driver.get firecloud_workspace
		assert !element_present?(:class, 'fa-check-circle'), 'did not revoke access - study workspace still loads'

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test validation of not allowing studies with an authorizationDomain attribute
	test 'admin: sync-study: restricted workspace' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# attempt to create a study using a workspace with a restricted authorizationDomain
		random_name = "Restricted Sync Test #{$random_seed}"
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys(random_name)
		study_form.find_element(:id, 'study_use_existing_workspace').send_keys('Yes')
		study_form.find_element(:id, 'study_firecloud_workspace').send_keys("development-authorization-domain-test-study")

		save_study = @driver.find_element(:id, 'save-study')
		save_study.click
		wait_for_render(:id, 'study-errors-block')
		error_message = @driver.find_element(:id, 'study-errors-block').find_element(:tag_name, 'li').text
		assert error_message.include?('The workspace you provided is restricted.'), "Did not find correct error message, expected 'The workspace you provided is restricted.' but found #{error_message}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## USER PROFILE TESTS
	## Setting email preferences, etc
	##

	test 'user-profiles: update email preferences' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		@driver.get @base_url + '/users/sign_in'
		login($test_email, $test_email_password)

		# open profile page
		profile = @driver.find_element(:id, 'profile-nav')
		profile.click
		profile_link = @driver.find_element(:id, 'my-profile')
		profile_link.click
		wait_for_render(:id, 'profile-header')

		# toggle admin emails
		admin_toggle = @driver.find_element(:id, 'toggle-admin-emails')
		admin_toggle.click
		@wait.until {admin_toggle.text == 'Off'}
		toggle_text = admin_toggle.text
		assert toggle_text == 'Off', "Did not properly turn off admin emails (text is still #{toggle_text})"
		admin_toggle.click
		@wait.until {admin_toggle.text == 'On'}
		new_toggle_text = admin_toggle.text
		assert new_toggle_text == 'On', "Did not properly turn on admin emails (text is still #{new_toggle_text})"

		# toggle study/share notification
		study_notifier_toggle = @driver.find_element(:class, 'toggle-study-subscription')
		study_notifier_toggle.click
		@wait.until {@driver.find_element(:class, 'toggle-study-subscription').text == 'Off'}
		study_text = study_notifier_toggle.text
		assert study_text == 'Off', "Did not properly turn off study notification (text is still #{study_text})"
		study_notifier_toggle.click
		@wait.until {@driver.find_element(:class, 'toggle-study-subscription').text == 'On'}
		new_study_text = study_notifier_toggle.text
		assert new_study_text == 'On', "Did not properly turn on study notification (text is still #{new_study_text})"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# update a user's FireCloud profile from the user profile section
	test 'user-profiles: update firecloud profile' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		@driver.get @base_url + '/users/sign_in'
		login($test_email, $test_email_password)

		# open profile page
		profile = @driver.find_element(:id, 'profile-nav')
		profile.click
		profile_link = @driver.find_element(:id, 'my-profile')
		profile_link.click
		wait_for_render(:id, 'profile-header')

		open_ui_tab('profile-firecloud')

		job_title_field = @driver.find_element(:id, 'firecloud_profile_title')
		job_title_field.clear
		new_title = "Random Title #{$random_seed}"
		job_title_field.send_keys(new_title)
		update_btn = @driver.find_element(:id, 'update-user-firecloud-profile')
		update_btn.click
		wait_for_modal_open('message_modal')

		# reload page to confirm save
		@driver.get @driver.current_url
		wait_for_render(:id, 'profile-header')
		open_ui_tab('profile-firecloud')

		job_title = @driver.find_element(:id, 'firecloud_profile_title')['value']
		assert job_title == new_title, "Did not update job title correctly, expected '#{new_title}' but found '#{job_title}'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## BILLING TESTS
	## Validate the portal can create and manage new FireCloud projects given existing billing projects/accounts
	## The user being used for the test must have an available Google billing project that they own for these tests to work
	##

	# create a new firecloud billing project
	test 'admin: billing-projects: create' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/billing_projects'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# create new billing project
		add_btn = @driver.find_element(:id, 'add-billing-project')
		add_btn.click
		wait_for_modal_open('new-firecloud-project-modal')

		# select available billing account and name project
		accounts = @driver.find_element(:id, 'billing_project_billing_account').find_elements(:tag_name, 'option').keep_if {|opt| !opt['value'].empty?}
		account = accounts.sample
		account.click
		name_field = @driver.find_element(:id, 'billing_project_project_name')
		# project names have a length limit, so shorten random seed element
		random_seed_slug = $random_seed.split('-').first
		project_name = "test-scp-project-#{random_seed_slug}"
		name_field.send_key(project_name)

		# save new billing project
		save_btn = @driver.find_element(:id, 'create-billing-project')
		save_btn.click

		# confirm project creation
		close_modal('message_modal')
		created_project = @driver.find_element(:id, project_name)
		assert !created_project.nil?, "Did not find a new project with the name #{project_name}"
		created_project_name = created_project.find_element(:class, 'project-name').text
		assert project_name == created_project_name, "Did not set name of project correctly, expected '#{project_name}' but found '#{created_project_name}'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# add users to a billing project
	test 'admin: billing-projects: manage users' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/billing_projects'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# add a user to newly created project
		random_seed_slug = $random_seed.split('-').first
		project_name = "test-scp-project-#{random_seed_slug}"
		project_path = path + "/#{project_name}/new_user"
		add_user_button = @driver.find_element(:id, project_name).find_element(:class, 'add-billing-project-user')
		add_user_button.click
		wait_until_page_loads(project_path)
		email_field = @driver.find_element(:id, 'billing_project_user_email')
		email_field.send_key($share_email)
		role_select = @driver.find_element(:id, 'billing_project_user_role')
		role_select.send_key('user')
		save_btn = @driver.find_element(:id, 'add-billing-project-user')
		save_btn.click
		wait_until_page_loads(path)
		close_modal('message_modal')

		# assert user was added
		email_id = "#{project_name}-#{$share_email.gsub(/[@\.]/, '-')}"
		assert element_present?(:id, email_id), "Did not successfully add user to billing project, could not find element with id: #{email_id}"

		# remove user
		remove_link = @driver.find_element(:id, project_name).find_element(:class, 'delete-billing-project-user')
		remove_link.click
		accept_alert
		close_modal('message_modal')

		# assert deletion
		assert !element_present?(:id, email_id), "Did not successfully remove user to billing project, found element with id: #{email_id}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# add a study to a newly created billing project
	test 'admin: billing-projects: add a study' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/studies/new'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# fill out study form
		study_form = @driver.find_element(:id, 'new_study')
		study_form.find_element(:id, 'study_name').send_keys("New Project Study #{$random_seed}")
		project = study_form.find_element(:id, 'study_firecloud_project')
		random_seed_slug = $random_seed.split('-').first
		project_name = "test-scp-project-#{random_seed_slug}"
		project.send_keys(project_name)
		# make sure dropdown changed to new project name
		assert project['value'] == project_name, "Did not set FireCloud project to correct value, expected #{project_name} but found #{project['value']}"
		# add a share
		share = @driver.find_element(:id, 'add-study-share')
		@wait.until {share.displayed?}
		share.click
		share_email = study_form.find_element(:class, 'share-email')
		share_email.send_keys($share_email)
		share_permission = study_form.find_element(:class, 'share-permission')
		share_permission.send_keys('Edit')
		# save study
		save_study = @driver.find_element(:id, 'save-study')
		save_study.click

		# upload expression matrix
		close_modal('message_modal')
		upload_expression = @driver.find_element(:id, 'upload-expression')
		upload_expression.send_keys(@test_data_path + 'expression_matrix_example.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		# close success modal
		close_modal('upload-success-modal')
		next_btn = @driver.find_element(:id, 'next-btn')
		next_btn.click

		# upload metadata
		wait_for_render(:id, 'metadata_form')
		upload_metadata = @driver.find_element(:id, 'upload-metadata')
		upload_metadata.send_keys(@test_data_path + 'metadata_example2.txt')
		wait_for_render(:id, 'start-file-upload')
		upload_btn = @driver.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# upload cluster
		cluster_form_1 = @driver.find_element(:class, 'initialize_ordinations_form')
		cluster_name = cluster_form_1.find_element(:class, 'filename')
		cluster_name.send_keys('Test Cluster 1')
		upload_cluster = cluster_form_1.find_element(:class, 'upload-clusters')
		upload_cluster.send_keys(@test_data_path + 'cluster_example_2.txt')
		wait_for_render(:id, 'start-file-upload')
		# perform upload
		upload_btn = cluster_form_1.find_element(:id, 'start-file-upload')
		upload_btn.click
		close_modal('upload-success-modal')

		# validate everything uploaded and parsed
		sleep(3)
		study_path = @base_url + '/study/' + "new-project-study-#{$random_seed}"
		@driver.get study_path
		wait_until_page_loads(study_path)
		open_ui_tab('study-download')
		files = @driver.find_elements(:class, 'dl-link').size
		assert files == 3, "Did not find correct nubmer of files to download, expected 3 but found #{files}"
		open_ui_tab('study-visualize')
		assert element_visible?(:id, 'cluster-plot'), 'Study visualizations are not enabled'

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# manage compute permissions for workspaces in a project
	test 'admin: billing-projects: compute permissions' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/billing_projects'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# make sure there is a project and a workspace
		assert element_present?(:class, 'billing-project'), 'Did not find any billing projects'
		random_seed_slug = $random_seed.split('-').first
		project_name = "test-scp-project-#{random_seed_slug}"
		workspaces_btn = @driver.find_element(:id, project_name).find_element(:class, 'view-workspaces')
		workspaces_btn.click
		wait_until_page_loads(path + "/#{project_name}/workspaces")
		assert @driver.find_elements(:class, 'project-workspace').any?, 'Did not find any project workspaces'

		# navigate to compute permissions page
		edit_compute = @driver.find_element(:class, 'edit-computes')
		edit_compute.click
		wait_for_render(:id, 'user-computes')

		# revoke compute permissions
		share_email_id = $share_email.gsub(/[@.]/, '-')
		form = @driver.find_element(:id, share_email_id)
		compute_permissions = form.find_element(:id, 'compute_can_compute')
		compute_permissions.send_key('No')
		update_btn = form.find_element(:class, 'update-compute-permissions')
		update_btn.click
		wait_for_modal_open('message_modal')
		notice = @driver.find_element(:id, 'notice-content').text
		assert notice.include?('successfully updated'), "Did not find correct notification, expected 'successfully updated' but found #{notice}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# view storage cost estimate for a project
	test 'admin: billing-projects: storage costs' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/billing_projects'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# navigate to storage page
		random_seed_slug = $random_seed.split('-').first
		project_name = "test-scp-project-#{random_seed_slug}"
		storage_btn = @driver.find_element(:id, project_name).find_element(:class, 'storage-estimate')
		storage_btn.click
		wait_until_page_loads(path + "/#{project_name}/storage_estimate")

		project_label = @driver.find_element(:id, 'project-name').text
		assert project_label == project_name, "Did not load correct project, expected '#{project_name}' but found '#{project_label}'"
		assert element_present?(:id, 'workspace-costs'), 'Did not find workspace costs table'

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## CONFIGURATIONS TESTS
	## Test AdminConfiguration functionality and other site admin features
	##

	# test the various levels of firecloud access integration (on, read-only, local-off, and off)
	test 'configurations: firecloud access' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/admin'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# show the 'panic' modal and disable downloads
		panic_modal_link = @driver.find_element(:id, 'show-panic-modal')
		panic_modal_link.click
		wait_for_modal_open('panic-modal')
		disable_button = @driver.find_element(:id, 'disable-firecloud-access')
		disable_button.click
		close_modal('message_modal')

		# assert access is revoked
		firecloud_url = "https://portal.firecloud.org/#workspaces/single-cell-portal/#{$env}-test-study-#{$random_seed}"
		@driver.get firecloud_url
		assert !element_present?(:class, 'fa-check-circle'), 'did not revoke access - study workspace still loads'

		# test that study admin access is disabled
		# go to homepage first to set referrer
		@driver.get @base_url
		studies_path = @base_url + '/studies'
		@driver.get studies_path
		assert element_present?(:id, 'message_modal'), 'did not show alert'
		assert @driver.current_url == @base_url, 'did not redirect to home page'

		# set access to readonly
		@driver.get path
		panic_modal_link = @driver.find_element(:id, 'show-panic-modal')
		panic_modal_link.click
		wait_for_modal_open('panic-modal')
		compute_button = @driver.find_element(:id, 'disable-compute-access')
		compute_button.click
		close_modal('message_modal')

		# assert access is revoked
		@driver.get firecloud_url
		assert !element_present?(:class, 'fa-trash'), 'did not revoke compute access - study workspace can still be deleted'

		# test that study admin access is disabled
		# go to homepage first to set referrer
		@driver.get @base_url
		studies_path = @base_url + '/studies'
		@driver.get studies_path
		assert element_present?(:id, 'message_modal'), 'did not show alert'
		assert @driver.current_url == @base_url, 'did not redirect to home page'

		# now restore access
		@driver.get path
		panic_modal_link = @driver.find_element(:id, 'show-panic-modal')
		panic_modal_link.click
		wait_for_modal_open('panic-modal')
		disable_button = @driver.find_element(:id, 'enable-firecloud-access')
		disable_button.click
		close_modal('message_modal')

		# assert access is restored, wait a few seconds for changes to propogate
		sleep(3)
		@driver.get firecloud_url
		assert element_present?(:class, 'fa-check-circle'), 'did not restore access - study workspace does not load'

		# assert study access is restored
		@driver.get studies_path
		assert element_present?(:id, 'studies'), 'did not find studies table'
		assert @driver.current_url == studies_path, 'did not load studies path correctly'

		# finally, check local-only option to block downloads and study access in the portal only
		@driver.get path
		panic_modal_link = @driver.find_element(:id, 'show-panic-modal')
		panic_modal_link.click
		wait_for_modal_open('panic-modal')
		local_access_button = @driver.find_element(:id, 'disable-local-access')
		local_access_button.click
		close_modal('message_modal')

		# assert firecloud projects are still accessible, but studies and downloads are not
		@driver.get firecloud_url
		assert element_present?(:class, 'fa-check-circle'), 'did maintain restore access - study workspace does not load'
		test_study_path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(test_study_path)
		wait_for_render(:id, 'study-download-nav')
		open_ui_tab('study-download')
		disabled_downloads = @driver.find_elements(:class, 'disabled-download')
		assert disabled_downloads.size > 0, 'did not disable downloads, found 0 disabled-download links'
		@driver.get studies_path
		assert element_present?(:id, 'message_modal'), 'did not show alert'
		assert @driver.current_url == @base_url, 'did not redirect to home page'

		# cleanup by restoring access
		@driver.get path
		panic_modal_link = @driver.find_element(:id, 'show-panic-modal')
		panic_modal_link.click
		wait_for_modal_open('panic-modal')
		disable_button = @driver.find_element(:id, 'enable-firecloud-access')
		disable_button.click
		close_modal('message_modal')

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# validate that the download quota will prevent user downloads once reached
	test 'configurations: quota: enforcement' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/admin'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# find quota object or create if needed
		if element_present?(:class, 'daily-user-download-quota-edit')
			quota_edit = @driver.find_element(:class, 'daily-user-download-quota-edit')
			quota_edit.click
			multiplier = @driver.find_element(:id, 'admin_configuration_multiplier')
			multiplier.send_key('byte')
			save = @driver.find_element(:id, 'save-configuration')
			save.click
			wait_until_page_loads(path)
			close_modal('message_modal')
		else
			create = @driver.find_element(id: 'create-new-configuration')
			create.click
			value = @driver.find_element(:id, 'admin_configuration_value')
			value.send_key(2)
			multiplier = @driver.find_element(:id, 'admin_configuration_multiplier')
			multiplier.send_key('byte')
			save = @driver.find_element(:id, 'save-configuration')
			save.click
			wait_until_page_loads(path)
			close_modal('message_modal')
		end

		# now test downloads
		study_path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(study_path)
		wait_until_page_loads(study_path)

		open_ui_tab('study-download')

		files = @driver.find_elements(:class, 'disabled-download')
		assert files.size >= 1, 'downloads not properly disabled (did not find any disabled-download links)'

		# try bypassing download with a direct call to file we uploaded earlier
		direct_link = @base_url + "/data/public/test-study-#{$random_seed}?filename=expression_matrix_example.txt"
		@driver.get direct_link
		alert_content = @driver.find_element(:id, 'alert-content')
		assert alert_content.text == 'You have exceeded your current daily download quota. You must wait until tomorrow to download this file.', 'download was not successfully blocked'

		# reset quota back to default, we don't need to test downloads again because that gets done in front-end: download study data file
		@driver.get path
		quota_edit = @driver.find_element(:class, 'daily-user-download-quota-edit')
		quota_edit.click
		multiplier = @driver.find_element(:id, 'admin_configuration_multiplier')
		multiplier.send_key('terabyte')
		save = @driver.find_element(:id, 'save-configuration')
		save.click
		wait_until_page_loads(path)
		close_modal('message_modal')

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test unlocking jobs feature - this mainly just tests that the request goes through. it is difficult to test the
	# entire method as it require the portal to crash while in the middle of a parse, which cannot be reliably automated.
	test 'configurations: restart locked jobs' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/users/sign_in'
		@driver.get path
		login($test_email, $test_email_password)
		@driver.get @base_url + '/admin'

		actions_dropdown = @driver.find_element(:id, 'admin_action')
		actions_dropdown.send_keys 'Unlock Orphaned Jobs'
		execute_button = @driver.find_element(:id, 'perform-admin-task')
		execute_button.click
		wait_for_modal_open('message_modal')
		assert element_visible?(:id, 'message_modal'), 'confirmation message did not appear'
		message = @driver.find_element(:id, 'notice-content').text
		assert message.include?('jobs'), "'confirmation message did not pertain to locked jobs ('jobs' not found)"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# reset user download quotas to 0 bytes
	test 'configurations: download-quota: reset' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/users/sign_in'
		@driver.get path
		login($test_email, $test_email_password)
		@driver.get @base_url + '/admin'

		actions_dropdown = @driver.find_element(:id, 'admin_action')
		actions_dropdown.send_keys 'Reset User Download Quotas'
		execute_button = @driver.find_element(:id, 'perform-admin-task')
		execute_button.click
		wait_for_modal_open('message_modal')
		assert element_visible?(:id, 'message_modal'), 'confirmation message did not appear'
		message = @driver.find_element(:id, 'notice-content').text
		expected_conf = 'All user download quotas successfully reset to 0.'
		assert message == expected_conf, "correct confirmation did not appear, expected #{expected_conf} but found #{message}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test force-refreshing the FireCloud API access tokens and storage driver connections
	test 'configurations: refresh api connections' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/admin'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		actions_dropdown = @driver.find_element(:id, 'admin_action')
		actions_dropdown.send_keys 'Refresh API Clients'
		execute_button = @driver.find_element(:id, 'perform-admin-task')
		execute_button.click
		wait_for_modal_open('message_modal')
		assert element_visible?(:id, 'message_modal'), 'confirmation message did not appear'
		message = @driver.find_element(:id, 'notice-content').text
		expected_conf = 'API Client successfully refreshed.'
		assert message.start_with?(expected_conf), "correct confirmation did not appear, expected #{expected_conf} but found #{message}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# update a user's roles (admin or reporter)
	test 'configurations: update user roles' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		path = @base_url + '/admin'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		open_ui_tab('users')
		share_email_id = $share_email.gsub(/[@.]/, '-')
		search_box = @driver.find_element(:xpath, "//div[@id='users']//input[@type='search']")
		search_box.send_keys($share_email)
		share_user_edit = @driver.find_element(:id, share_email_id + '-edit')
		share_user_edit.click
		wait_for_render(:id, 'user_reporter')
		user_reporter = @driver.find_element(:id, 'user_reporter')
		user_reporter.send_keys('Yes')
		save_btn = @driver.find_element(:id, 'save-user')
		save_btn.click

		# assert that reporter access was granted
		close_modal('message_modal')
		open_ui_tab('users')
		search_box = @driver.find_element(:xpath, "//div[@id='users']//input[@type='search']")
		search_box.send_keys($share_email)
		assert element_present?(:id, share_email_id + '-reporter'), "did not grant reporter access to #{$share_email}"

		# now remove to reset for future tests
		share_user_edit = @driver.find_element(:id, share_email_id + '-edit')
		share_user_edit.click
		wait_for_render(:id, 'user_reporter')
		user_reporter = @driver.find_element(:id, 'user_reporter')
		user_reporter.send_keys('No')
		save_btn = @driver.find_element(:id, 'save-user')
		save_btn.click

		# assert that reporter access was removed
		close_modal('message_modal')
		open_ui_tab('users')
		search_box = @driver.find_element(:xpath, "//div[@id='users']//input[@type='search']")
		search_box.send_keys($share_email)
		share_roles = @driver.find_element(:id, share_email_id + '-roles')
		assert share_roles.text == '', "did not remove reporter access from #{$share_email}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test whether or not maintenance mode functions properly
	# technically this is not an AdminConfiguration, but a bash script that only a project admin can invoke
	test 'configurations: maintenance mode' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		# only execute this test when testing locally - when using a remote host it will fail as the shell script being executed
		# is on the wrong host
		omit_if !$portal_url.include?('localhost'), 'cannot enable maintenance mode on remote host' do
			# enable maintenance mode
			system("#{@base_path}/bin/enable_maintenance.sh on")
			@driver.get @base_url
			assert element_present?(:id, 'maintenance-notice'), 'could not load maintenance page'
			# disable maintenance mode
			system("#{@base_path}/bin/enable_maintenance.sh off")
			@driver.get @base_url
			assert element_present?(:id, 'main-banner'), 'could not load home page'
			puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
		end
	end

	# test sending an email to users
	test 'configurations: email all users' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/admin'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		email_users_btn = @driver.find_element(:id, 'email-all-users')
		email_users_btn.click
		wait_until_page_loads(path + '/email_users/compose')

		subject = @driver.find_element(:id, 'email_subject')
		subject.send_keys('This is the subject')
		@driver.switch_to.frame(@driver.find_element(:tag_name, 'iframe'))
		message = @driver.find_element(:class, 'cke_editable')
		message_content = "This is an email to all users."
		message.send_keys(message_content)
		@driver.switch_to.default_content

		# send preview email
		preview_btn = @driver.find_element(:id, 'deliver-preview-email')
		preview_btn.click
		wait_for_modal_open('message_modal')
		notification = @driver.find_element(:id, 'notice-content')
		assert notification.text == 'Your email has successfully been delivered.', "Did not find correct notification, expeceted 'Your email has successfully been delivered.' but found '#{notification.text}'"
		close_modal('message_modal')
		sleep(2)

		# send regular email
		deliver_btn = @driver.find_element(:id, 'deliver-users-email')
		deliver_btn.click
		wait_for_modal_open('message_modal')
		new_notification = @driver.find_element(:id, 'notice-content')
		assert new_notification.text == 'Your email has successfully been delivered.', "Did not find correct notification, expeceted 'Your email has successfully been delivered.' but found '#{new_notification.text}'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## REPORTS TESTS
	## View portal statistics through the reports page
	##

	# test loading plots from reporting controller
	test 'reports: view' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/reports'
		@driver.get(path)
		close_modal('message_modal')
		login($test_email, $test_email_password)

		# check for reports
		report_plots = @driver.find_elements(:class, 'plotly-report')
		assert report_plots.size == 9, "did not find correct number of plots, expected 9 but found #{report_plots.size}"
		report_plots.each do |plot|
			rendered = @driver.execute_script("return $('##{plot['id']}').data('rendered')")
			assert rendered, "#{plot['id']} rendered status was not true"
		end

		# test toggle column total button
		toggle_btn = @driver.find_element(:id, 'toggle-column-annots')

		# turn off
		toggle_btn.click
		@wait.until {wait_for_plotly_render('#plotly-study-email-domain-dist', 'rendered')}
		new_layout = @driver.execute_script("return document.getElementById('plotly-study-email-domain-dist').layout")
		assert new_layout['annotations'].nil?, "did not turn off annotations, expected nil but found #{new_layout['annotations']}"

		# turn on
		toggle_btn.click
		@wait.until {wait_for_plotly_render('#plotly-study-email-domain-dist', 'rendered')}
		layout = @driver.execute_script("return document.getElementById('plotly-study-email-domain-dist').layout")
		assert !layout['annotations'].nil?, "did not turn on annotations, expected annotations array but found #{layout['annotations']}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# send a request to site admins for a new report plot
	test 'reports: request new' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/reports'
		@driver.get(path)
		close_modal('message_modal')
		login($test_email, $test_email_password)

		request_modal = @driver.find_element(:id, 'report-request')
		request_modal.click
		wait_for_modal_open('contact-modal')

		@driver.switch_to.frame(@driver.find_element(:tag_name, 'iframe'))
		message = @driver.find_element(:class, 'cke_editable')
		message_content = "This is a report request."
		message.send_keys(message_content)
		@driver.switch_to.default_content
		send_request = @driver.find_element(:id, 'send-report-request')
		send_request.click
		wait_for_modal_open('message_modal')
		assert element_visible?(:id, 'message_modal'), 'confirmation modal did not show.'
		notice_content = @driver.find_element(:id, 'notice-content')
		confirmation_message = 'Your message has been successfully delivered.'
		assert notice_content.text == confirmation_message, "did not find confirmation message, expected #{confirmation_message} but found #{notice_content.text}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	###
	#
	# FRONT-END TESTS
	#
	###

	##
	## FRONT-END BASIC TESTS
	## Covers basic front-end functionality (mostly the study overview page)
	##

	# get the homepage
	test 'front-end: view: home page' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		@driver.get(@base_url)
		assert element_present?(:id, 'main-banner'), 'could not find index page title text'
		assert @driver.find_elements(:class, 'panel-primary').size >= 1, 'did not find any studies'
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# search for studies
	test 'front-end: search' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		@driver.get(@base_url)
		search_box = @driver.find_element(:id, 'search_terms')
		search_box.send_keys("#{$random_seed}")
		submit = @driver.find_element(:id, 'submit-search')
		submit.click
		studies = @driver.find_elements(:class, 'study-panel').size
		assert studies >= 2, 'incorrect number of studies found. expected >= 2 but found ' + studies.to_s
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# view study overview pages
	test 'front-end: view: study' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		assert element_present?(:class, 'study-lead'), 'could not find study title'
		assert element_present?(:id, 'cluster-plot'), 'could not find study cluster plot'

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert rendered, "cluster plot did not finish rendering, expected true but found #{rendered}"

		# check for coordinate labels
		labels = @driver.execute_script("return layout.scene.annotations;")
		assert_not_nil labels, 'Did not return coordinate labels'
		assert labels.size == 8, "Did not find coorect number of coordinate labels, expected 8 but found #{labels.size}"

		# load subclusters
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		clusters = @driver.find_element(:id, 'cluster').find_elements(:tag_name, 'option')
		assert clusters.size == 2, "incorrect number of clusters found, expected 2 but found #{clusters.size}"
		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		assert annotations.size == 5, "incorrect number of annotations found, expected 5 but found #{annotations.size}"
		annotations.select {|opt| opt.text == 'Sub-Cluster'}.first.click

		# wait for render again
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		sub_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert sub_rendered, "cluster plot did not finish rendering on change, expected true but found #{sub_rendered}"
		legend = @driver.find_elements(:class, 'traces').size
		assert legend == 6, "incorrect number of traces found in Sub-Cluster, expected 6 - found #{legend}"

		# testing loading all annotation types
		annotations_values = annotations.map{|x| x['value']}
		annotations_values.each do |annotation|
			@driver.find_element(:id, 'annotation').send_key annotation
			@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
			cluster_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
			assert cluster_rendered, "cluster plot did not finish rendering on change, expected true but found #{cluster_rendered}"
		end

		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		private_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert private_rendered, "private cluster plot did not finish rendering, expected true but found #{private_rendered}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# download a study file
	test 'front-end: download: study file' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		login_path = @base_url + '/users/sign_in'
		# downloads require login now
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-download')

		files = @driver.find_elements(:class, 'dl-link')
		file_link = files.sample
		filename = file_link['data-filename']
		basename = filename.split('.').first
		@wait.until { file_link.displayed? }
		# perform 'Save as' action
		download_file(file_link, basename)
		# since we don't do HTML5 downloads, and the webdriver context menu is very unreliable...


		# now download a file from a private study
		private_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get(private_path)
		wait_until_page_loads(private_path)
		open_ui_tab('study-download')

		private_files = @driver.find_elements(:class, 'dl-link')
		private_file_link = private_files.first
		private_filename = private_file_link['download']
		private_basename = private_filename.split('.').first
		@wait.until { private_file_link.displayed? }
		download_file(private_file_link, private_basename)

		# logout
		logout_from_portal

		# now login as share user and test downloads
		@driver.get login_path
		wait_until_page_loads(login_path)
		login_as_other($share_email, $share_email_password)

		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-download')

		files = @driver.find_elements(:class, 'dl-link')
		share_file_link = files.first
		share_filename = share_file_link['data-filename']
		share_basename = share_filename.split('.').first
		@wait.until { share_file_link.displayed? }
		download_file(share_file_link, share_basename)

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test view/edit restrictions on private studies
	test 'front-end: download: privacy restriction' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($share_email, $share_email_password)

		# negative test, should not be able to download private files from study without access
		non_share_public_link = @base_url + "/data/public/private-study-#{$random_seed}?filename=README.txt"
		non_share_private_link = @base_url + "/data/private/private-study-#{$random_seed}?filename=README.txt"

		# try public rout
		@driver.get non_share_public_link
		public_alert_text = @driver.find_element(:id, 'alert-content').text
		assert public_alert_text == 'You do not have permission to perform that action.',
					 "did not properly redirect, expected 'You do not have permission to perform that action.' but got #{public_alert_text}"

		# try private route
		@driver.get non_share_private_link
		wait_for_modal_open('message_modal')
		private_alert_text = @driver.find_element(:id, 'alert-content').text
		assert private_alert_text == 'You do not have permission to perform that action.',
					 "did not properly redirect, expected 'You do not have permission to perform that action.' but got #{private_alert_text}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	test 'front-end: download: bulk data' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		# downloads require login now
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($share_email, $share_email_password)

		path = @base_url + "/study/sync-test-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-download')

		# open download help modal
		download_modal = @driver.find_element(id: 'download-help')
		download_modal.click
		wait_for_modal_open('download-help-modal')

		# get command for all data download
		all_data_link = @driver.find_element(:id, 'get-download-command_all')
		all_data_link.click
		wait_for_render(:class, 'curl-download-command')
		command_value = @driver.find_element(:class, 'curl-download-command')['value']

		# run command and verify that download works
		system("cd #{$download_dir}; mkdir #{$random_seed}; cd #{$random_seed}; #{command_value}")
		bulk_path = File.join($download_dir, $random_seed)
		files_found = Dir.entries(bulk_path).keep_if {|entry| !entry.start_with?('.')}.size
		assert files_found > 0, 'did not download any files'

		# clean up
		FileUtils.rm_rf(bulk_path)

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test that axes are rendering custom domains and labels properly
	test 'front-end: validation: axis domains and labels' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		assert element_present?(:class, 'study-lead'), 'could not find study title'
		assert element_present?(:id, 'cluster-plot'), 'could not find study cluster plot'

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert rendered, "cluster plot did not finish rendering, expected true but found #{rendered}"

		# get layout object from browser and verify labels & ranges
		layout = @driver.execute_script('return layout;')
		assert layout['scene']['xaxis']['range'] == [-100, 100], "X range was not correctly set, expected [-100, 100] but found #{layout['scene']['xaxis']['range']}"
		assert layout['scene']['yaxis']['range'] == [-75, 75], "Y range was not correctly set, expected [-75, 75] but found #{layout['scene']['xaxis']['range']}"
		assert layout['scene']['zaxis']['range'] == [-125, 125], "Z range was not correctly set, expected [-125, 125] but found #{layout['scene']['xaxis']['range']}"
		assert layout['scene']['xaxis']['title'] == 'X Axis', "X title was not set correctly, expected 'X Axis' but found #{layout['scene']['xaxis']['title']}"
		assert layout['scene']['yaxis']['title'] == 'Y Axis', "Y title was not set correctly, expected 'Y Axis' but found #{layout['scene']['yaxis']['title']}"
		assert layout['scene']['zaxis']['title'] == 'Z Axis', "Z title was not set correctly, expected 'Z Axis' but found #{layout['scene']['zaxis']['title']}"
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test that toggle traces button works
	test 'front-end: validation: toggle traces button' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		assert element_present?(:class, 'study-lead'), 'could not find study title'
		assert element_present?(:id, 'cluster-plot'), 'could not find study cluster plot'

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert rendered, "cluster plot did not finish rendering, expected true but found #{rendered}"

		# toggle traces off
		toggle = @driver.find_element(:id, 'toggle-traces')
		toggle.click

		# check visiblity
		visible = @driver.execute_script('return data[0].visible')
		assert visible == 'legendonly', "did not toggle trace visibility, expected 'legendonly' but found #{visible}"

		# toggle traces on
		toggle.click

		# check visiblity
		visible = @driver.execute_script('return data[0].visible')
		assert visible == true, "did not toggle trace visibility, expected 'true' but found #{visible}"
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## FRONT-END: SEARCHING EXPRESSION DATA
	## Tests front-end functionality when searching for genes and viewing expression data
	##

	# search for a single gene and view plots
	test 'front-end: search-genes: single' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		# perform negative search first to test redirect
		bad_gene = 'foo'
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(bad_gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		wait_for_modal_open('message_modal')
		alert_text = @driver.find_element(:id, 'alert-content')
		assert alert_text.text == 'No matches found for: foo.', 'did not redirect and display alert correctly'
		close_modal('message_modal')

		# load random gene to search
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		assert element_present?(:id, 'box-controls'), 'could not find expression violin plot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		# confirm queried gene is the one returned
		queried_gene = @driver.find_element(:class, 'queried-gene')
		assert queried_gene.text == gene, "did not load the correct gene, expected #{gene} but found #{queried_gene.text}"

		# testing loading all annotation types
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotations_values = annotations.map{|x| x['value']}
		annotations_values.each do |annotation|
			@driver.find_element(:id, 'annotation').send_key annotation
			type = annotation.split('--')[1]
			$verbose ? puts( "loading annotation: #{annotation}") : nil
			if type == 'group'
				# if looking at box, switch back to violin
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')

				is_box_plot = plot_ops.select {|opt| opt.selected?}.sample.text == 'Box Plot'
				if is_box_plot
					new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
					plot_dropdown.send_key(new_plot)
				end
				# wait until violin plot renders, at this point all 3 should be done

				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new kernel
				kernel_dropdown = @driver.find_element(:id, 'kernel_type')
				kernel_ops = kernel_dropdown.find_elements(:tag_name, 'option')
				new_kernel = kernel_ops.select {|opt| !opt.selected?}.sample.text
				kernel_dropdown.send_key(new_kernel)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot kernel did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new bandwidth
				bandwidth_dropdown = @driver.find_element(:id, 'band_type')
				band_ops = bandwidth_dropdown.find_elements(:tag_name, 'option')
				new_band = band_ops.select {|opt| !opt.selected?}.sample.text
				bandwidth_dropdown.send_key(new_band)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot bandwidth did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# change to box plot
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
				new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
				plot_dropdown.send_key(new_plot)

				# wait until box plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

			else
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"
			end

		end
		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		new_gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(new_gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		assert element_present?(:id, 'box-controls'), 'could not find expression boxplot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		# confirm queried gene is the one returned
		new_queried_gene = @driver.find_element(:class, 'queried-gene')
		assert new_queried_gene.text == new_gene, "did not load the correct gene, expected #{new_gene} but found #{new_queried_gene.text}"

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot did not finish rendering, expected true but found #{private_violin_rendered}"
		private_scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert private_scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{private_scatter_rendered}"
		private_reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert private_reference_rendered, "private reference plot did not finish rendering, expected true but found #{private_reference_rendered}"

		# select new kernel
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		private_kernel_dropdown = @driver.find_element(:id, 'kernel_type')
		private_kernel_ops = private_kernel_dropdown.find_elements(:tag_name, 'option')
		private_new_kernel = private_kernel_ops.select {|opt| !opt.selected?}.sample.text
		private_kernel_dropdown.send_key(private_new_kernel)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot kernel did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# select new bandwidth
		private_bandwidth_dropdown = @driver.find_element(:id, 'band_type')
		private_band_ops = private_bandwidth_dropdown.find_elements(:tag_name, 'option')
		private_new_band = private_band_ops.select {|opt| !opt.selected?}.sample.text
		private_bandwidth_dropdown.send_key(private_new_band)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot bandwidth did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		private_plot_dropdown = @driver.find_element(:id, 'plot_type')
		private_plot_ops = private_plot_dropdown.find_elements(:tag_name, 'option')
		private_new_plot = private_plot_ops.select {|opt| !opt.selected?}.sample.text
		private_plot_dropdown.send_key(private_new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_box_rendered, "private box plot did not finish rendering, expected true but found #{private_box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	# search for multiple genes, but collapse using a consensus metric and view plots
	test 'front-end: search-genes: multiple consensus' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		# load random genes to search, take between 2-5, adding in bad gene to test error handling
		genes = @genes.shuffle.take(rand(2..5))
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_keys(genes.join(' ') + ' foo')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		consensus = @driver.find_element(:id, 'search_consensus')

		# select a random consensus measurement
		opts = consensus.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'None'}
		selected_consensus = opts.sample
		selected_consensus_value = selected_consensus['value']
		selected_consensus.click

		assert element_present?(:id, 'box-controls'), 'could not find expression boxplot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'
		assert element_present?(:id, 'missing-genes'), 'did not find missing genes list'

		# confirm queried genes and selected consensus are correct
		queried_genes = @driver.find_elements(:class, 'queried-gene').map(&:text)
		assert genes.sort == queried_genes.sort, "found incorrect genes, expected #{genes.sort} but found #{queried_genes.sort}"
		queried_consensus = @driver.find_element(:id, 'selected-consensus')
		assert selected_consensus_value == queried_consensus.text, "did not load correct consensus metric, expected #{selected_consensus_value} but found #{queried_consensus.text}"

		# testing loading all annotation types
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		# open distribution control panel as well
		view_options_panel = @driver.find_element(:id, 'distribution-panel-link')
		view_options_panel.click
		wait_for_render(:id, 'distribution-plot-controls')

		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotations_values = annotations.map{|x| x['value']}
		annotations_values.each do |annotation|
			@driver.find_element(:id, 'annotation').send_key annotation
			type = annotation.split('--')[1]
			$verbose ? puts( "loading annotation: #{annotation}") : nil
			if type == 'group'
				# if looking at box, switch back to violin
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')

				is_box_plot = plot_ops.select {|opt| opt.selected?}.sample.text == 'Box Plot'
				if is_box_plot
					new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
					plot_dropdown.send_key(new_plot)
				end
				# wait until violin plot renders, at this point all 3 should be done

				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new kernel
				kernel_dropdown = @driver.find_element(:id, 'kernel_type')
				kernel_ops = kernel_dropdown.find_elements(:tag_name, 'option')
				new_kernel = kernel_ops.select {|opt| !opt.selected?}.sample.text
				kernel_dropdown.send_key(new_kernel)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot kernel did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new bandwidth
				bandwidth_dropdown = @driver.find_element(:id, 'band_type')
				band_ops = bandwidth_dropdown.find_elements(:tag_name, 'option')
				new_band = band_ops.select {|opt| !opt.selected?}.sample.text
				bandwidth_dropdown.send_key(new_band)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot bandwidth did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# change to box plot
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
				new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
				plot_dropdown.send_key(new_plot)

				# wait until box plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

			else
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"
			end

		end
		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		new_genes = @genes.shuffle.take(rand(2..5))
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_keys(new_genes.join(' '))

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		new_consensus = @driver.find_element(:id, 'search_consensus')

		# select a random consensus measurement
		new_opts = new_consensus.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'None'}
		new_selected_consensus = new_opts.sample
		new_selected_consensus_value = new_selected_consensus['value']
		new_selected_consensus.click

		assert element_present?(:id, 'box-controls'), 'could not find expression boxplot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		# confirm queried genes are correct
		new_queried_genes = @driver.find_elements(:class, 'queried-gene').map(&:text)
		assert new_genes.sort == new_queried_genes.sort, "found incorrect genes, expected #{new_genes.sort} but found #{new_queried_genes.sort}"
		new_queried_consensus = @driver.find_element(:id, 'selected-consensus')
		assert new_selected_consensus_value == new_queried_consensus.text, "did not load correct consensus metric, expected #{new_selected_consensus_value} but found #{new_queried_consensus.text}"

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot did not finish rendering, expected true but found #{private_violin_rendered}"
		private_scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert private_scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{private_scatter_rendered}"
		private_reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert private_reference_rendered, "private reference plot did not finish rendering, expected true but found #{private_reference_rendered}"

		# select new kernel
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		# open distribution control panel as well
		view_options_panel = @driver.find_element(:id, 'distribution-panel-link')
		view_options_panel.click
		wait_for_render(:id, 'distribution-plot-controls')

		private_kernel_dropdown = @driver.find_element(:id, 'kernel_type')
		private_kernel_ops = private_kernel_dropdown.find_elements(:tag_name, 'option')
		private_new_kernel = private_kernel_ops.select {|opt| !opt.selected?}.sample.text
		private_kernel_dropdown.send_key(private_new_kernel)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot kernel did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# select new bandwidth
		private_bandwidth_dropdown = @driver.find_element(:id, 'band_type')
		private_band_ops = private_bandwidth_dropdown.find_elements(:tag_name, 'option')
		private_new_band = private_band_ops.select {|opt| !opt.selected?}.sample.text
		private_bandwidth_dropdown.send_key(private_new_band)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot bandwidth did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		private_plot_dropdown = @driver.find_element(:id, 'plot_type')
		private_plot_ops = private_plot_dropdown.find_elements(:tag_name, 'option')
		private_new_plot = private_plot_ops.select {|opt| !opt.selected?}.sample.text
		private_plot_dropdown.send_key(private_new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_box_rendered, "private box plot did not finish rendering, expected true but found #{private_box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	# search for multiple genes and view as a heatmap
	test 'front-end: search-genes: multiple heatmap' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		# load random genes to search, take between 2-5
		genes = @genes.shuffle.take(rand(2..5))
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_keys(genes.join(' '))
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		wait_for_render(:id, 'heatmap-plot')

		assert element_present?(:id, 'plots'), 'could not find expression heatmap'
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotations_values = annotations.map{|x| x['value']}
		annotations_values.each do |annotation|
			@driver.find_element(:id, 'annotation').send_key annotation
			@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
			heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
			assert heatmap_drawn, "heatmap plot encountered error, expected true but found #{heatmap_drawn}"
		end

		heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert heatmap_drawn, "heatmap plot encountered error, expected true but found #{heatmap_drawn}"

		# confirm queried genes are correct
		queried_genes = @driver.find_elements(:class, 'queried-gene').map(&:text)
		assert genes.sort == queried_genes.sort, "found incorrect genes, expected #{genes.sort} but found #{queried_genes.sort}"

		# resize heatmap
		scroll_to(:bottom)
		heatmap_size = @driver.find_element(:id, 'heatmap_size')
		heatmap_size.send_key(1000)
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}

		resize_heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert resize_heatmap_drawn, "heatmap plot encountered error, expected true but found #{resize_heatmap_drawn}"

		# toggle fullscreen
		fullscreen = @driver.find_element(:id, 'view-fullscreen')
		fullscreen.click
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		fullscreen_heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert fullscreen_heatmap_drawn, "heatmap plot encountered error, expected true but found #{fullscreen_heatmap_drawn}"
		search_opts_visible = element_visible?(:id, 'search-options-panel')
		assert !search_opts_visible, "fullscreen mode did not launch correctly, expected search options visibility == false but found #{!search_opts_visible}"

		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		new_genes = @genes.shuffle.take(rand(2..5))
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_keys(new_genes.join(' '))
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		assert element_present?(:id, 'plots'), 'could not find expression heatmap'
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		private_rendered = @driver.execute_script("return $('#heatmap-plot').data('rendered')")
		assert private_rendered, "private heatmap plot did not finish rendering, expected true but found #{private_rendered}"
		private_heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert private_heatmap_drawn, "heatmap plot encountered error, expected true but found #{private_heatmap_drawn}"

		# confirm queried genes are correct
		new_queried_genes = @driver.find_elements(:class, 'queried-gene').map(&:text)
		assert new_genes.sort == new_queried_genes.sort, "found incorrect genes, expected #{new_genes.sort} but found #{new_queried_genes.sort}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	# search for multiple genes by uploading a text file of gene names
	test 'front-end: search-genes: multiple upload file' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		# upload gene list
		search_upload = @driver.find_element(:id, 'search_upload')
		search_upload.send_keys(@test_data_path + 'search_genes.txt')

		assert element_present?(:id, 'plots'), 'could not find expression heatmap'
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert heatmap_drawn, "heatmap plot encountered error, expected true but found #{heatmap_drawn}"

		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		search_upload = @driver.find_element(:id, 'search_upload')
		search_upload.send_keys(@test_data_path + 'search_genes.txt')
		search_genes = @driver.find_element(:id, 'perform-gene-search')

		assert element_present?(:id, 'plots'), 'could not find expression heatmap'
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		private_heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert private_heatmap_drawn, "heatmap plot encountered error, expected true but found #{private_heatmap_drawn}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	# view a list of marker genes as a heatmap
	test 'front-end: marker-gene: heatmap' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)

		expression_list = @driver.find_element(:id, 'expression')
		opts = expression_list.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		expression_list.send_keys(gene_list_name)
		assert element_present?(:id, 'heatmap-plot'), 'could not find heatmap plot'

		# wait for heatmap to render
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert heatmap_drawn, "heatmap plot encountered error, expected true but found #{heatmap_drawn}"

		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)

		private_expression_list = @driver.find_element(:id, 'expression')
		opts = private_expression_list.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		private_expression_list.send_keys(gene_list_name)
		assert element_present?(:id, 'heatmap-plot'), 'could not find heatmap plot'

		# wait for heatmap to render
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}
		private_heatmap_drawn = @driver.execute_script("return $('#heatmap-plot').data('morpheus').heatmap !== undefined;")
		assert private_heatmap_drawn, "heatmap plot encountered error, expected true but found #{private_heatmap_drawn}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	# view a list of marker genes as distribution plots
	test 'front-end: marker-gene: box/scatter' do
		puts "Test method: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)

		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		gene_sets.send_keys(gene_list_name)
		assert element_present?(:id, 'expression-plots'), 'could not find box/scatter divs'

		# testing loading all annotation types
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		# open distribution control panel as well
		view_options_panel = @driver.find_element(:id, 'distribution-panel-link')
		view_options_panel.click
		wait_for_render(:id, 'distribution-plot-controls')

		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotations_values = annotations.map{|x| x['value']}
		annotations_values.each do |annotation|
			@driver.find_element(:id, 'annotation').send_key annotation
			type = annotation.split('--')[1]
			$verbose ? puts( "loading annotation: #{annotation}") : nil
			if type == 'group'
				# if looking at box, switch back to violin
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')

				is_box_plot = plot_ops.select {|opt| opt.selected?}.sample.text == 'Box Plot'
				if is_box_plot
					new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
					plot_dropdown.send_key(new_plot)
				end
				# wait until violin plot renders, at this point all 3 should be done

				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new kernel
				kernel_dropdown = @driver.find_element(:id, 'kernel_type')
				kernel_ops = kernel_dropdown.find_elements(:tag_name, 'option')
				new_kernel = kernel_ops.select {|opt| !opt.selected?}.sample.text
				kernel_dropdown.send_key(new_kernel)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot kernel did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# select new bandwidth
				bandwidth_dropdown = @driver.find_element(:id, 'band_type')
				band_ops = bandwidth_dropdown.find_elements(:tag_name, 'option')
				new_band = band_ops.select {|opt| !opt.selected?}.sample.text
				bandwidth_dropdown.send_key(new_band)

				# wait until violin plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert violin_rendered, "violin plot bandwidth did not finish rendering, expected true but found #{violin_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

				# change to box plot
				plot_dropdown = @driver.find_element(:id, 'plot_type')
				plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
				new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
				plot_dropdown.send_key(new_plot)

				# wait until box plot renders, at this point all 3 should be done
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

			else
				@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
				box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
				assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
				scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
				assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
				reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
				assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"
			end

		end

		# now test private study
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)
		private_study_path = @base_url + "/study/private-study-#{$random_seed}"
		@driver.get private_study_path
		wait_until_page_loads(private_study_path)
		open_ui_tab('study-visualize')

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)

		private_gene_sets = @driver.find_element(:id, 'gene_set')
		opts = private_gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		private_gene_sets.send_keys(gene_list_name)
		assert element_present?(:id, 'expression-plots'), 'could not find box/scatter divs'

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot did not finish rendering, expected true but found #{private_violin_rendered}"
		private_scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert private_scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{private_scatter_rendered}"
		private_reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert private_reference_rendered, "private reference plot did not finish rendering, expected true but found #{private_reference_rendered}"

		# select new kernel
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		# open distribution control panel as well
		view_options_panel = @driver.find_element(:id, 'distribution-panel-link')
		view_options_panel.click
		wait_for_render(:id, 'distribution-plot-controls')

		private_kernel_dropdown = @driver.find_element(:id, 'kernel_type')
		private_kernel_ops = private_kernel_dropdown.find_elements(:tag_name, 'option')
		private_new_kernel = private_kernel_ops.select {|opt| !opt.selected?}.sample.text
		private_kernel_dropdown.send_key(private_new_kernel)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot kernel did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# select new bandwidth
		private_bandwidth_dropdown = @driver.find_element(:id, 'band_type')
		private_band_ops = private_bandwidth_dropdown.find_elements(:tag_name, 'option')
		private_new_band = private_band_ops.select {|opt| !opt.selected?}.sample.text
		private_bandwidth_dropdown.send_key(private_new_band)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_violin_rendered, "private violin plot bandwidth did not finish rendering, expected true but found #{private_violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		private_plot_dropdown = @driver.find_element(:id, 'plot_type')
		private_plot_ops = private_plot_dropdown.find_elements(:tag_name, 'option')
		private_new_plot = private_plot_ops.select {|opt| !opt.selected?}.sample.text
		private_plot_dropdown.send_key(private_new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		private_box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert private_box_rendered, "private box plot did not finish rendering, expected true but found #{private_box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "private scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "private reference plot did not finish rendering, expected true but found #{reference_rendered}"

		puts "Test method: '#{self.method_name}' successful!"
	end

	##
	## FRONT-END VALIDATION TESTS
	## Tests statefulness of views when switching back and forth between plots and editing study defaults,
	## as well as validations for bespoke visualizations
	##

	# These are unit tests in actuality, but are put in UI test because of docker issues with networking
	test 'front-end: validation: kernel density and bandwidth functions' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		# load website
		path = @base_url
		@driver.get(path)

		# known array with known median and quartile values
		test_array = [1,2,3,4,5]

		# calculate median, min, max and quartiles with simple statistics
		quartile = @driver.execute_script("return ss.quantile(#{test_array}, [0.25, 0.75])")
		median = @driver.execute_script("return ss.median(#{test_array})")

		min = @driver.execute_script("return getMinOfArray(#{test_array})")
		max = @driver.execute_script("return getMaxOfArray(#{test_array})")

		$verbose ? puts( 'Testing basic violin plot math functions (quartile, median, min, max)') : nil

		# Median should be 3, quartiles should be 2 and 4, max should be 5 and min should be 1
		assert (quartile[0] == 2 and quartile[1] == 4), 'Quartiles are incorrect: '  + quartile[0].to_s +  ' ' + quartile[1].to_s
		assert median == 3, 'Median is incorrect: ' + median.to_s
		assert min == test_array.min, 'Min is incorrect: '  + min.to_s
		assert max == test_array.max, 'Max is incorrect: ' + max.to_s

		$verbose ? puts( 'Testing higher level violin plot math functions (isOutlier, cutOutliers)') : nil

		# Array with known outliers
		outlier_test_array = [-2.6, 2, 3, 4, 5, 9.6]

		# -2.6 should be an outlier
		is_outlier = @driver.execute_script("return isOutlier(#{outlier_test_array[0]}, ss.quantile(#{outlier_test_array}, [0.25]), ss.quantile(#{outlier_test_array}, 0.75) )")
		assert is_outlier, 'Outlier incorrectly not identified ' + outlier_test_array[0].to_s

		# 9.6 should be an outlier
		is_outlier = @driver.execute_script("return isOutlier(#{outlier_test_array[5]}, ss.quantile(#{outlier_test_array}, [0.25]), ss.quantile(#{outlier_test_array}, 0.75))")
		assert is_outlier, 'Outlier incorrectly not identified ' + outlier_test_array[5].to_s

		# 2 should not be an outlier
		is_outlier = @driver.execute_script("return isOutlier(#{outlier_test_array[1]}, ss.quantile(#{outlier_test_array}, [0.25]), ss.quantile(#{outlier_test_array}, 0.75) )")
		assert !is_outlier, 'Outlier incorrectly not identified ' + outlier_test_array[1].to_s

		# 5 should not be and outlier
		is_outlier = @driver.execute_script("return isOutlier(#{outlier_test_array[4]}, ss.quantile(#{outlier_test_array}, [0.25]), ss.quantile(#{outlier_test_array}, 0.75))")
		assert !is_outlier, 'Outlier incorrectly not identified ' + outlier_test_array[4].to_s

		# [-2.6,9.6] should be the outliers and the non outliers should be an array of the remaining numbers
		cut_outliers = @driver.execute_script("return cutOutliers(#{outlier_test_array}, ss.quantile(#{outlier_test_array}, [0.25]), ss.quantile(#{outlier_test_array}, 0.75) )")
		assert (cut_outliers[1] == outlier_test_array[1..4] and cut_outliers[0] == [outlier_test_array[5], outlier_test_array[0]]), "Cut outlier incorrect: " + cut_outliers.to_s

		$verbose ? puts( 'Testing highest level math (Kernel Distrbutions)') : nil

		# Python KDE stats only has the seven following functions that match what I have found in JavaScript

		# Testing array. Prime numbers from 0 to 200, there are 46 of them
		kernel_test_array = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193, 197, 199]
		# 'Correct' kernel density scores for bandwidth of 1 found with python using given kernel
		correct_gaussian = [0.006458511, 0.006704709, 0.006930598, 0.007137876, 0.007325677, 0.007493380, 0.007640600, 0.007765395, 0.007866591, 0.007948254, 0.008011220, 0.008056486, 0.008085195, 0.008097190, 0.008094063, 0.008079507, 0.008054997, 0.008021980, 0.007981867, 0.007935508, 0.007884712, 0.007831191, 0.007775831, 0.007719392, 0.007662512, 0.007605775, 0.007549610, 0.007494102, 0.007439251, 0.007384972, 0.007331100, 0.007277341, 0.007223212, 0.007168332, 0.007112321, 0.007054804, 0.006995414, 0.006933322, 0.006868407, 0.006800656, 0.006729964, 0.006656295, 0.006579689, 0.006499781, 0.006417373, 0.006333001, 0.006247130, 0.006160288, 0.006073060, 0.005986391, 0.005901149, 0.005818017, 0.005737680, 0.005660796, 0.005587986, 0.005521125, 0.005459697, 0.005403935, 0.005354035, 0.005310096, 0.005272153, 0.005241391, 0.005215990, 0.005195542, 0.005179576, 0.005167573, 0.005159043, 0.005153719, 0.005150272, 0.005148195, 0.005147039, 0.005146420, 0.005146032, 0.005145642, 0.005145223, 0.005144887, 0.005144833, 0.005145338, 0.005146855, 0.005150204, 0.005155697, 0.005163818, 0.005175027, 0.005189754, 0.005208731, 0.005232706, 0.005261083, 0.005293823, 0.005330777, 0.005371676, 0.005416408, 0.005464253, 0.005513915, 0.005564550, 0.005615250, 0.005665050, 0.005712526, 0.005756092, 0.005795032, 0.005828404, 0.005855330, 0.005875007, 0.005885486, 0.005886195, 0.005877750, 0.005859974, 0.005832824, 0.005796389, 0.005749557, 0.005693563, 0.005629906, 0.005559324, 0.005482642, 0.005400763, 0.005314198, 0.005224866, 0.005134150, 0.005043127, 0.004952863, 0.004864400, 0.004779599, 0.004699329, 0.004624223, 0.004555018, 0.004492369, 0.004436849, 0.004390707, 0.004352999, 0.004323594, 0.004302562, 0.004289882, 0.004285444, 0.004290800, 0.004303732, 0.004323604, 0.004349863, 0.004381892, 0.004419015, 0.004461274, 0.004506556, 0.004554040, 0.004602904, 0.004652336, 0.004701519, 0.004749184, 0.004794769, 0.004837739, 0.004877644, 0.004914130, 0.004946798, 0.004974849, 0.004999204, 0.005020085, 0.005037808, 0.005052771, 0.005065368, 0.005076192, 0.005086308, 0.005096331, 0.005106854, 0.005118437, 0.005131756, 0.005147592, 0.005165873, 0.005186704, 0.005210078, 0.005235877, 0.005264020, 0.005294000, 0.005324895, 0.005356059, 0.005386791, 0.005416352, 0.005443623, 0.005467395, 0.005487267, 0.005502614, 0.005512890, 0.005517635, 0.005515662, 0.005506797, 0.005491790, 0.005470785, 0.005444031, 0.005411875, 0.005374134, 0.005331887, 0.005286271, 0.005237941, 0.005187557, 0.005135772, 0.005083230, 0.005030777, 0.004978903, 0.004927967, 0.004878250, 0.004829951, 0.004783476, 0.004738592, 0.004695064, 0.004652704, 0.004611278, 0.004570516, 0.004530086, 0.004489503, 0.004448456, 0.004406668, 0.004363890, 0.004319908, 0.004274198, 0.004226930, 0.004178133, 0.004127851, 0.004076178, 0.004023255, 0.003969125, 0.003914399, 0.003859427, 0.003804588, 0.003750299, 0.003697033, 0.003645860, 0.003597095, 0.003551323, 0.003509150, 0.003471201, 0.003438299, 0.003412449, 0.003393210, 0.003381210, 0.003377055, 0.003381319, 0.003395026, 0.003420270, 0.003455536, 0.003501052, 0.003556954, 0.003623284, 0.003700685, 0.003789968, 0.003888784, 0.003996593, 0.004112753, 0.004236532, 0.004367589, 0.004504956, 0.004646475, 0.004791066, 0.004937624, 0.005085031, 0.005231962, 0.005376721, 0.005518343, 0.005655847, 0.005788308, 0.005914859, 0.006033708, 0.006143816, 0.006245485, 0.006338210, 0.006421545, 0.006495100, 0.006556999, 0.006607250, 0.006646755, 0.006675343, 0.006692865, 0.006699190, 0.006692309, 0.006672956, 0.006642072, 0.006599599, 0.006545500, 0.006479753, 0.006400226, 0.006308339, 0.006205035, 0.006090492, 0.005964940, 0.005828671, 0.005680088, 0.005521449, 0.005353893, 0.005178116, 0.004994894, 0.004805079, 0.004608735, 0.004408365, 0.004205311, 0.004000794, 0.003796082, 0.003592481, 0.003392475, 0.003197246, 0.003008108, 0.002826383, 0.002653365, 0.002490376, 0.002341774, 0.002206092, 0.002084244, 0.001977039, 0.001885178, 0.001809668, 0.001754406, 0.001715866, 0.001694045, 0.001688800, 0.001699855, 0.001727470, 0.001773267, 0.001833064, 0.001905907, 0.001990752, 0.002086467, 0.002192342, 0.002307525, 0.002428836, 0.002554924, 0.002684450, 0.002816102, 0.002948529, 0.003079951, 0.003209217, 0.003335404, 0.003457689, 0.003575357, 0.003687211, 0.003792342, 0.003891336, 0.003984063, 0.004070474, 0.004150597, 0.004223799, 0.004290241, 0.004350936, 0.004406057, 0.004455757, 0.004500159, 0.004538618, 0.004571254, 0.004598559, 0.004620374, 0.004636493, 0.004646669, 0.004649556, 0.004645117, 0.004633689, 0.004615054, 0.004589063, 0.004555638, 0.004513538, 0.004463858, 0.004407624, 0.004345440, 0.004278052, 0.004206342, 0.004131069, 0.004054394, 0.003977845, 0.003902825, 0.003830752, 0.003763050, 0.003702807, 0.003650661, 0.003607420, 0.003573970, 0.003551019, 0.003539089, 0.003541133, 0.003554551, 0.003578687, 0.003612899, 0.003656360, 0.003708065, 0.003768047, 0.003832764, 0.003900730, 0.003970441, 0.004040397, 0.004109064, 0.004173898, 0.004234040, 0.004288483, 0.004336376, 0.004377030, 0.004409621, 0.004432374, 0.004447067, 0.004453949, 0.004453409, 0.004445966, 0.004431963, 0.004411786, 0.004387558, 0.004360194, 0.004330617, 0.004299742, 0.004268527, 0.004238240, 0.004209644, 0.004183362, 0.004159934, 0.004139811, 0.004123728, 0.004112228, 0.004104749, 0.004101230, 0.004101526, 0.004105416, 0.004112913, 0.004123483, 0.004136189, 0.004150517, 0.004165933, 0.004181891, 0.004197733, 0.004212671, 0.004226245, 0.004238031, 0.004247656, 0.004254804, 0.004258775, 0.004259530, 0.004257355, 0.004252333, 0.004244617, 0.004234434, 0.004221815, 0.004207526, 0.004192219, 0.004176401, 0.004160602, 0.004145368, 0.004131626, 0.004119968, 0.004110791, 0.004104526, 0.004101552, 0.004102188, 0.004107531, 0.004117076, 0.004130604, 0.004147981, 0.004168974, 0.004193262, 0.004220858, 0.004250398, 0.004281098, 0.004312181, 0.004342811, 0.004372110, 0.004398220, 0.004420522, 0.004438160, 0.004450319, 0.004456257, 0.004455221, 0.004444834, 0.004426568, 0.004400399, 0.004366476, 0.004325129, 0.004276684, 0.004221132, 0.004161141, 0.004097981, 0.004033050, 0.003967851, 0.003904166, 0.003844910, 0.003791456, 0.003745408, 0.003708280, 0.003681479, 0.003667195, 0.003668345, 0.003683375, 0.003712662, 0.003756347, 0.003814336, 0.003887447, 0.003975606, 0.004075393, 0.004185505, 0.004304476, 0.004430689, 0.004562687, 0.004697753, 0.004833136, 0.004966854, 0.005096942, 0.005221466, 0.005337262, 0.005441706, 0.005534243, 0.005613460, 0.005678080, 0.005726968, 0.005756528, 0.005766355, 0.005757846, 0.005730731, 0.005684900, 0.005620398, 0.005534493, 0.005429287, 0.005307138, 0.005168893, 0.005015526, 0.004848127, 0.004665931]
		correct_epanechnikov =  [0.00847826,  0.01030435,  0.01082609,  0.00834783,  0.00717391,  0.00717391,  0.00717391,  0.00717391,  0.00443478,  0.006,  0.006,  0.00443478,  0.00717391,  0.00717391,  0.00443478, 0.00326087,  0.006,  0.006,  0.00443478,  0.00717391,  0.006,  0.00443478,  0.00443478, 0.00326087,  0.00443478,  0.00717391,  0.00717391,  0.00717391,  0.00717391,  0.00443478, 0.00443478,  0.00443478,  0.006,  0.006,  0.006,  0.006,  0.00326087,  0.00443478,  0.00443478,  0.00326087,  0.006,  0.006,  0.006,  0.00717391,  0.00717391,  0.006]

		# Script kernel density scores
		test_gaussian = @driver.execute_script("return kernelDensityEstimator(kernelGaussian(5), genRes(46, 2, 199))(#{kernel_test_array})").map{|v| v[1]}

		test_epanechnikov = @driver.execute_script("return kernelDensityEstimator(kernelEpanechnikov(5.0), #{kernel_test_array})(#{kernel_test_array})").map{|v| v[1]}

		# Testing if script kernel density scores match 'correct' kernel density scores within 0.1% accuracy
		assert compare_within_rounding_error(0.01, correct_gaussian, test_gaussian), "Gaussian failure: " + correct_gaussian.to_s + 'Test'+ test_gaussian.to_s
		assert compare_within_rounding_error(0.02, correct_epanechnikov, test_epanechnikov), "Epanechnikov failure: " + correct_epanechnikov.to_s + "\nTest\n" + test_epanechnikov.to_s

		# Testing if kernel density scores identify as incorrect if compared against known incorrect data within 0.1% accuracy.
		# Known incorrect data is correct data with first element increased by 0.1
		incorrect_gaussian = correct_gaussian.map{|x| x * 1.1}
		incorrect_epanechnikov = correct_epanechnikov.map{|x| x * 1.1}

		# Test if not incorrect
		assert !compare_within_rounding_error(0.01, incorrect_gaussian, test_gaussian), "Gaussian Incorrect failure: " + incorrect_gaussian.to_s + test_gaussian.to_s
		assert !compare_within_rounding_error(0.01, incorrect_epanechnikov, test_epanechnikov), "Epanechnikov Incorrect failure: " + incorrect_epanechnikov.to_s + test_epanechnikov.to_s
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# tests that form values for loaded clusters & annotations are being persisted when switching between different views and using 'back' button in search box
	test 'front-end: validation: cluster and annotation persistence' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		clusters = @driver.find_element(:id, 'cluster').find_elements(:tag_name, 'option')
		cluster = clusters.last
		cluster_name = cluster['text']
		cluster.click

		# wait for render to complete
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		cluster_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert cluster_rendered, "cluster plot did not finish rendering on cluster change, expected true but found #{cluster_rendered}"

		# select an annotation and wait for render
		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotation = annotations.sample
		annotation_value = annotation['value']
		annotation.click
		$verbose ? puts( "Using annotation #{annotation_value}") : nil
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# now search for a gene and make sure values are preserved
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# wait for rendering to complete
		assert element_present?(:id, 'expression-plots'), 'could not find box/scatter divs'

		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "box plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# now check values
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		loaded_cluster = @driver.find_element(:id, 'cluster')
		loaded_annotation = @driver.find_element(:id, 'annotation')
		assert loaded_cluster['value'] == cluster_name, "did not load correct cluster; expected #{cluster_name} but loaded #{loaded_cluster['value']}"
		assert loaded_annotation['value'] == annotation_value, "did not load correct annotation; expected #{annotation_value} but loaded #{loaded_annotation['value']}"

		# now check the back button in the search box to make sure it preserves values
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		back_btn = @driver.find_element(:id, 'clear-gene-search')
		back_btn.click
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		sleep(1)
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		current_cluster = @driver.find_element(:id, 'cluster')
		current_annotation = @driver.find_element(:id, 'annotation')
		assert current_cluster['value'] == cluster_name, "did not load correct cluster after back button; expected #{cluster_name} but loaded #{current_cluster['value']}"
		assert current_annotation['value'] == annotation_value, "did not load correct annotation after back button; expected #{current_annotation} but loaded #{current_annotation['value']}"

		# now search for multiple genes as a heatmap
		genes = @genes.shuffle.take(rand(2..5))
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_keys(genes.join(' '))
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		assert element_present?(:id, 'plots'), 'could not find expression heatmap'
		@wait.until {wait_for_morpheus_render('#heatmap-plot', 'morpheus')}

		# click back button in search box
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		back_btn = @driver.find_element(:id, 'clear-gene-search')
		back_btn.click
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		heatmap_cluster =  @driver.find_element(:id, 'cluster')['value']
		heatmap_annot = @driver.find_element(:id, 'annotation')['value']
		assert heatmap_cluster == cluster_name, "cluster was not preserved correctly from heatmap view, expected #{cluster_name} but found #{heatmap_cluster}"
		assert heatmap_annot == annotation_value, "cluster was not preserved correctly from heatmap view, expected #{annotation_value} but found #{heatmap_annot}"

		# show gene list in scatter mode
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(0.5)

		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		gene_sets.send_keys(gene_list_name)

		assert element_present?(:id, 'expression-plots'), 'could not find box/scatter divs'
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}

		# click back button in search box
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		back_btn = @driver.find_element(:id, 'clear-gene-search')
		back_btn.click
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		gene_list_cluster =  @driver.find_element(:id, 'cluster')['value']
		gene_list_annot = @driver.find_element(:id, 'annotation')['value']
		assert gene_list_cluster == cluster_name, "cluster was not preserved correctly from gene list scatter view, expected #{cluster_name} but found #{gene_list_cluster}"
		assert gene_list_annot == annotation_value, "cluster was not preserved correctly from gene list scatter view, expected #{gene_list_annot} but found #{heatmap_annot}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test that camera position is being preserved on cluster/annotation select & rotation
	test 'front-end: validation: camera position on change' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get(path)
		wait_until_page_loads(path)
		open_ui_tab('study-visualize')

		assert element_present?(:class, 'study-lead'), 'could not find study title'
		assert element_present?(:id, 'cluster-plot'), 'could not find study cluster plot'

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert rendered, "cluster plot did not finish rendering, expected true but found #{rendered}"

		# get camera data
		camera = @driver.execute_script("return $('#cluster-plot').data('camera');")
		# set new rotation
		camera['eye']['x'] = (Random.rand * 10 - 5).round(4)
		camera['eye']['y'] = (Random.rand * 10 - 5).round(4)
		camera['eye']['z'] = (Random.rand * 10 - 5).round(4)
		# call relayout to trigger update & camera position save
		@driver.execute_script("Plotly.relayout('cluster-plot', {'scene': {'camera' : #{camera.to_json}}});")

		# wait a second for event to fire, then get new camera
		sleep(1)
		new_camera = @driver.execute_script("return $('#cluster-plot').data('camera');")
		assert camera == new_camera, "camera position did not save correctly, expected #{camera.to_json}, got #{new_camera.to_json}"
		# load annotation
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		annotations.select {|opt| opt.text == 'Sub-Cluster'}.first.click

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# verify camera position was saved
		annot_camera = @driver.execute_script("return $('#cluster-plot').data('camera');")
		assert camera == annot_camera, "camera position did not save correctly, expected #{camera.to_json}, got #{annot_camera.to_json}"

		# load new cluster
		clusters = @driver.find_element(:id, 'cluster').find_elements(:tag_name, 'option')
		cluster = clusters.last
		cluster.click

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		cluster_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert cluster_rendered, "cluster plot did not finish rendering on cluster change, expected true but found #{cluster_rendered}"

		# verify camera position was saved
		cluster_camera = @driver.execute_script("return $('#cluster-plot').data('camera');")
		assert camera == cluster_camera, "camera position did not save correctly, expected #{camera.to_json}, got #{cluster_camera.to_json}"

		# now check gene expression views
		# load random gene to search
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}

		# get camera data
		scatter_camera = @driver.execute_script("return $('#expression-plots').data('scatter-camera');")
		# set new rotation
		scatter_camera['eye']['x'] = (Random.rand * 10 - 5).round(4)
		scatter_camera['eye']['y'] = (Random.rand * 10 - 5).round(4)
		scatter_camera['eye']['z'] = (Random.rand * 10 - 5).round(4)
		# call relayout to trigger update & camera position save
		@driver.execute_script("Plotly.relayout('scatter-plot', {'scene': {'camera' : #{scatter_camera.to_json}}});")

		# wait a second for event to fire, then get new camera
		sleep(1)
		new_scatter_camera = @driver.execute_script("return $('#expression-plots').data('scatter-camera');")
		assert scatter_camera == new_scatter_camera, "scatter camera position did not save correctly, expected #{scatter_camera.to_json}, got #{new_scatter_camera.to_json}"

		# load annotation
		exp_annotations = @driver.find_element(:id, 'annotation').find_elements(:tag_name, 'option')
		exp_annotations.select {|opt| opt.text == 'Cluster'}.first.click

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#expression-plots', 'scatter-rendered')}
		annot_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# verify camera position was saved
		exp_annot_camera = @driver.execute_script("return $('#expression-plots').data('scatter-camera');")
		assert scatter_camera == exp_annot_camera, "camera position did not save correctly, expected #{scatter_camera.to_json}, got #{exp_annot_camera.to_json}"

		# load new cluster
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		clusters = @driver.find_element(:id, 'cluster').find_elements(:tag_name, 'option')
		cluster = clusters.first
		cluster.click

		# wait until cluster finishes rendering
		@wait.until {wait_for_plotly_render('#expression-plots', 'scatter-rendered')}
		exp_cluster_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert exp_cluster_rendered, "cluster plot did not finish rendering on cluster change, expected true but found #{exp_cluster_rendered}"

		# verify camera position was saved
		exp_cluster_camera = @driver.execute_script("return $('#expression-plots').data('scatter-camera');")
		assert scatter_camera == exp_cluster_camera, "camera position did not save correctly, expected #{scatter_camera.to_json}, got #{exp_cluster_camera.to_json}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# change the default study options and verify they are being preserved across views
	# this is a blend of admin and front-end tests and is run last as has the potential to break previous tests
	test 'front-end: validation: study default options' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		show_study = @driver.find_element(:class, "test-study-#{$random_seed}-show")
		show_study.click

		# change cluster
		options_form = @driver.find_element(:id, 'default-study-options-form')
		cluster_dropdown = options_form.find_element(:id, 'study_default_options_cluster')
		cluster_opts = cluster_dropdown.find_elements(:tag_name, 'option')
		new_cluster = cluster_opts.select {|opt| !opt.selected?}.sample.text
		cluster_dropdown.send_key(new_cluster)

		# wait one second while annotation options update
		sleep(1)

		# change annotation
		annotation_dropdown = options_form.find_element(:id, 'study_default_options_annotation')
		annotation_opts = annotation_dropdown.find_elements(:tag_name, 'option')
		# get value, not text, of dropdown
		new_annot = annotation_opts.select {|opt| !opt.selected?}.sample['value']
		annotation_dropdown.send_key(new_annot)

		# if annotation option is now numeric, pick a color val
		new_color = ''
		color_dropdown = options_form.find_element(:id, 'study_default_options_color_profile')
		if color_dropdown['disabled'] != 'true'
			color_opts = color_dropdown.find_elements(:tag_name, 'option')
			new_color = color_opts.select {|opt| !opt.selected?}.sample.text
			color_dropdown.send_key(new_color)
		end

		# change expression axis label
		expression_label = options_form.find_element(:id, 'study_default_options_expression_label')
		new_exp_label = 'Gene Expression Scores'
		expression_label.clear
		expression_label.send_keys(new_exp_label)

		# change cluster point size, turn off borders, and reduce alpha
		cluster_point_size = options_form.find_element(:id, 'study_default_options_cluster_point_size')
		cluster_point_size.clear
		cluster_point_size.send_keys(8)
		cluster_borders = options_form.find_element(:id, 'study_default_options_cluster_point_border')
		cluster_borders.send_keys('No')
		cluster_alpha = options_form.find_element(:id, 'study_default_options_cluster_point_alpha')
		cluster_alpha.clear
		cluster_alpha.send_keys(0.5)

		# save options
		options_form.submit
		close_modal('study-file-notices')

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		open_ui_tab('study-visualize')

		# assert values have persisted
		loaded_cluster = @driver.find_element(:id, 'cluster')['value']
		loaded_annotation = @driver.find_element(:id, 'annotation')['value']
		cluster_point_size = @driver.execute_script("return data[0].marker.size[0];")
		cluster_border = @driver.execute_script("return data[0].marker.line.width;").to_f
		cluster_alpha_val = @driver.execute_script("return data[0].opacity;").to_f
		assert new_cluster == loaded_cluster, "default cluster incorrect, expected #{new_cluster} but found #{loaded_cluster}"
		assert new_annot == loaded_annotation, "default annotation incorrect, expected #{new_annot} but found #{loaded_annotation}"
		assert cluster_point_size == 8, "default cluster point size incorrect, expected 8 but found #{cluster_point_size}"
		assert cluster_border == 0.0, "default cluster border incorrect, expected 0.0 but found #{cluster_border}"
		assert cluster_alpha_val == 0.5, "default cluster alpha incorrect, expected 0.5 but found #{cluster_alpha_val}"
		unless new_color.empty?
			loaded_color = @driver.find_element(:id, 'colorscale')['value']
			assert new_color == loaded_color, "default color incorrect, expected #{new_color} but found #{loaded_color}"
		end

		# now check gene expression pages
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}

		exp_loaded_cluster = @driver.find_element(:id, 'cluster')['value']
		exp_loaded_annotation = @driver.find_element(:id, 'annotation')['value']
		# open scatter tab
		scatter_link = @driver.find_element(:id, 'scatter-link')
		scatter_link.click
		wait_for_render(:id, 'scatter-plots')
		exp_loaded_label = @driver.find_element(:class, 'cbtitle').text
		assert new_cluster == exp_loaded_cluster, "default cluster incorrect, expected #{new_cluster} but found #{exp_loaded_cluster}"
		assert new_annot == exp_loaded_annotation, "default annotation incorrect, expected #{new_annot} but found #{exp_loaded_annotation}"
		assert exp_loaded_label == new_exp_label, "default expression label incorrect, expected #{new_exp_label} but found #{exp_loaded_label}"

		unless new_color.empty?
			exp_loaded_color = @driver.find_element(:id, 'colorscale')['value']
			assert new_color == exp_loaded_color, "default color incorrect, expected #{new_color} but found #{exp_loaded_color}"
		end

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# update a study via the study settings panel
	test 'front-end: validation: edit study settings' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)

		# update description first
		edit_btn = @driver.find_element(:id, 'edit-study-description')
		edit_btn.click
		wait_for_render(:id, 'update-study-description')
		# since ckeditor is a seperate DOM, we need to switch to the iframe containing it
		@driver.switch_to.frame(@driver.find_element(:tag_name, 'iframe'))
		description = @driver.find_element(:class, 'cke_editable')
		description.clear
		new_description = "This is the description with a random element: #{SecureRandom.uuid}."
		description.send_keys(new_description)
		@driver.switch_to.default_content
		update_btn = @driver.find_element(:id, 'update-study-description')
		update_btn.click
		wait_for_render(:id, 'edit-study-description')

		study_description = @driver.find_element(:id, 'study-description-content').text
		assert study_description == new_description, "study description did not update correctly, expected #{new_description} but found #{study_description}"

		# update default options
		close_modal('message_modal')
		open_ui_tab('study-settings')
		options_form = @driver.find_element(:id, 'default-study-options-form')
		cluster_dropdown = options_form.find_element(:id, 'study_default_options_cluster')
		cluster_opts = cluster_dropdown.find_elements(:tag_name, 'option')
		new_cluster = cluster_opts.select {|opt| !opt.selected?}.sample.text
		cluster_dropdown.send_key(new_cluster)
		# change cluster point size, turn on borders, and reset alpha
		cluster_point_size = options_form.find_element(:id, 'study_default_options_cluster_point_size')
		cluster_point_size.clear
		cluster_point_size.send_keys(6)
		cluster_borders = options_form.find_element(:id, 'study_default_options_cluster_point_border')
		cluster_borders.send_keys('Yes')
		cluster_alpha = options_form.find_element(:id, 'study_default_options_cluster_point_alpha')
		cluster_alpha.clear
		cluster_alpha.send_keys(1)

		# wait one second while annotation options update
		sleep(1)

		# change annotation
		annotation_dropdown = options_form.find_element(:id, 'study_default_options_annotation')
		annotation_opts = annotation_dropdown.find_elements(:tag_name, 'option')
		# get value, not text, of dropdown
		new_annot = annotation_opts.select {|opt| !opt.selected?}.sample['value']
		annotation_dropdown.send_key(new_annot)

		# if annotation option is now numeric, pick a color val
		new_color = ''
		color_dropdown = options_form.find_element(:id, 'study_default_options_color_profile')
		if color_dropdown['disabled'] != 'true'
			color_opts = color_dropdown.find_elements(:tag_name, 'option')
			new_color = color_opts.select {|opt| !opt.selected?}.sample.text
			color_dropdown.send_key(new_color)
		end

		# set cell count
		new_cells = rand(100) + 1
		cell_count = @driver.find_element(:id, 'study_cell_count')
		cell_count.clear
		cell_count.send_key(new_cells)

		# manually set rendered to false to avoid a race condition when checking for updates
		@driver.execute_script("$('#cluster-plot').data('rendered', false);")
		# now save changes
		update_btn = @driver.find_element(:id, 'update-study-settings')
		update_btn.click
		close_modal('message_modal')
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		# assert values have persisted
		open_ui_tab('study-visualize')
		loaded_cluster = @driver.find_element(:id, 'cluster')['value']
		loaded_annotation = @driver.find_element(:id, 'annotation')['value']
		cluster_point_size = @driver.execute_script("return data[0].marker.size[0];")
		cluster_border = @driver.execute_script("return data[0].marker.line.width;").to_f
		cluster_alpha_val = @driver.execute_script("return data[0].opacity;").to_f
		assert new_cluster == loaded_cluster, "default cluster incorrect, expected #{new_cluster} but found #{loaded_cluster}"
		assert new_annot == loaded_annotation, "default annotation incorrect, expected #{new_annot} but found #{loaded_annotation}"
		assert cluster_point_size == 6, "default cluster point size incorrect, expected 8 but found #{cluster_point_size}"
		assert cluster_border == 0.5, "default cluster border incorrect, expected 0.0 but found #{cluster_border}"
		assert cluster_alpha_val == 1.0, "default cluster alpha incorrect, expected 0.5 but found #{cluster_alpha_val}"

		unless new_color.empty?
			loaded_color = @driver.find_element(:id, 'colorscale')['value']
			assert new_color == loaded_color, "default color incorrect, expected #{new_color} but found #{loaded_color}"
		end
		new_cell_count = @driver.find_element(:id, 'cell-count').text.split.first.to_i
		assert new_cell_count == new_cells, "cell count did not update, expected #{new_cells} but found #{new_cell_count}"

		# now test if auth challenge is working properly using test study
		open_new_page(@base_url)
		logout_from_portal

		# check authentication challenge
		@driver.switch_to.window(@driver.window_handles.first)
		open_ui_tab('study-settings')
		public_dropdown = @driver.find_element(:id, 'study_public')
		public_dropdown.send_keys('Yes')
		update_btn = @driver.find_element(:id, 'update-study-settings')
		update_btn.click
		wait_for_modal_open('message_modal')
		alert_text = @driver.find_element(:id, 'alert-content').text
		assert alert_text == 'Your session has expired. Please log in again to continue.', "incorrect alert text - expected 'Your session has expired.  Please log in again to continue.' but found #{alert_text}"
		close_modal('message_modal')

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## USER ANNOTATION TESTS
	## Tests CRUDing UserAnnotation objects, as well as sharing and publishing
	##

	# Create a user annotation
	test 'front-end: user-annotation: creation' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# first confirm that you cannot create an annotation on a 3d study
		test_study_path = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get test_study_path
		wait_until_page_loads(test_study_path)
		open_ui_tab('study-visualize')
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		select_dropdown = @driver.find_element(:id, 'create_annotations_panel')
		select_dropdown.click
		# let collapse animation complete
		sleep(2)
		enable_select_button = @driver.find_element(:id, 'toggle-scatter')
		enable_select_button.click
		alert = @driver.switch_to.alert
		alert_text = alert.text
		assert alert_text == 'You may not create annotations on 3d data.  Please select a different cluster before continuing.',
					 "did not find correct alert, expected 'You may not create annotations on 3d data.  Please select a different cluster before continuing.' but found '#{}'"
		alert.accept

		# go to the 2d scatter plot study
		two_d_study_path = @base_url + "/study/twod-study-#{$random_seed}"
		@driver.get two_d_study_path
		wait_until_page_loads(two_d_study_path)
		open_ui_tab('study-visualize')

		# Click selection tab
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		select_dropdown = @driver.find_element(:id, 'create_annotations_panel')
		select_dropdown.click
		# let collapse animation complete
		sleep(2)

		# Enable Selection
		wait_for_render(:id, 'toggle-scatter')
		enable_select_button = @driver.find_element(:id, 'toggle-scatter')
		enable_select_button.click
		# let plot redraw
		wait_for_render(:id, 'selection-well')

		# click box select button
		select_button = @driver.find_element(:xpath, "//a[@data-val='select']")
		select_button.click

		# get the points in the plotly trace
		points = @driver.find_elements(:class, 'point')
		el1 = points[0]

		# click on the first point
		@driver.action.click_and_hold(el1).perform

		# wait for web driver
		sleep 0.5

		# drag the cursor to another point and release it
		el2 = points[-1]
		@driver.action.move_to(el2).release.perform

		# wait for plotly and webdriver
		sleep 1.0

		# send the keys for the name of the annotation
		annotation_name = @driver.find_element(:class, 'annotation-name')
		name = "user-#{$random_seed}"
		annotation_name.send_keys(name)
		# send keys to the labels of the annotation
		annotation_labels = @driver.find_elements(:class, 'annotation-label')
		annotation_labels.each_with_index do |annot, i|
			annot.send_keys("group#{i}")
		end

		sleep 0.5

		# create the annotation
		submit_button = @driver.find_element(:id, 'selection-submit')
		submit_button.click

		close_modal('message_modal')

		# choose the user annotation
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		annotation_dropdown = @driver.find_element(:id, 'annotation')
		annotation_dropdown.send_keys("user-#{$random_seed}")
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		# make sure the new annotation still renders a plot for plotly
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		@driver.find_element(:id, 'search-genes-link').click
		wait_for_render(:id, 'search-genes-form')

		# load random gene to search
		scroll_to(:top)
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# make sure the new annotation still renders plots for plotly
		assert element_present?(:id, 'box-controls'), 'could not find expression violin plot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		# confirm queried gene is the one returned
		queried_gene = @driver.find_element(:class, 'queried-gene')
		assert queried_gene.text == gene, "did not load the correct gene, expected #{gene} but found #{queried_gene.text}"

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		plot_dropdown = @driver.find_element(:id, 'plot_type')
		plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
		new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
		plot_dropdown.send_key(new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)
		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		gene_sets.send_keys(gene_list_name)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# Create an annotation from the gene page.  Due to the size of rendered elements, the only reproducible way to click the
		# annotation selection button is to scroll to the top, close the search panel, and open the annotation panel
		scroll_to(:top)
		# open scatter tab
		scatter_link = @driver.find_element(:id, 'scatter-link')
		scatter_link.click
		wait_for_render(:id, 'scatter-plots')
		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')

		# Click selection tabs
		select_dropdown = @driver.find_element(:id, 'create_annotations_panel')
		select_dropdown.click
		# let collapse animation complete
		sleep(2)
		# Enable Selection
		enable_select_button = @driver.find_element(:id, 'toggle-scatter')
		enable_select_button.click
		wait_for_render(:id, 'selection-well')

		# select the scatter plot
		plot = @driver.find_element(:id, 'scatter-plot')

		# click box select button
		scroll_to(:bottom)
		@wait.until {wait_for_plotly_render('#expression-plots', 'scatter-rendered')}
		select_button = @driver.find_elements(:xpath, "//a[@data-val='select']")[1]
		select_button.click

		# get the points in the plotly trace
		points = plot.find_elements(:class, 'point')
		el1 = points[0]

		# click on the first point
		@driver.action.click_and_hold(el1).perform

		# wait for web driver
		sleep 0.5

		# drag the cursor to another point and release it
		el2 = points[-1]
		@driver.action.move_to(el2).release.perform

		# wait for plotly and webdriver
		sleep 1.0

		# send the keys for the name of the annotation
		annotation_name = @driver.find_element(:class, 'annotation-name')
		name = "user-#{$random_seed}-exp"
		annotation_name.send_keys(name)
		# send keys to the labels of the annotation
		annotation_labels = @driver.find_elements(:class, 'annotation-label')
		annotation_labels.each_with_index do |annot, i|
			annot.send_keys("group#{i}")
		end

		sleep 0.5

		# create the annotation
		submit_button = @driver.find_element(:id, 'selection-submit')
		submit_button.click

		close_modal('message_modal')

		@driver.get two_d_study_path
		wait_until_page_loads(two_d_study_path)
		open_ui_tab('study-visualize')

		# choose the user annotation
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		annotation_dropdown = @driver.find_element(:id, 'annotation')
		annotation_dropdown.send_keys("user-#{$random_seed}-exp")
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		# make sure the new annotation still renders a plot for plotly
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# load random gene to search
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		wait_for_render(:id, 'perform-gene-search')
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# make sure the new annotation still renders plots for plotly
		assert element_present?(:id, 'box-controls'), 'could not find expression violin plot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		sleep 0.50

		# confirm queried gene is the one returned
		queried_gene = @driver.find_element(:class, 'queried-gene')
		assert queried_gene.text == gene, "did not load the correct gene, expected #{gene} but found #{queried_gene.text}"

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')

		plot_dropdown = @driver.find_element(:id, 'plot_type')
		plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
		new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
		plot_dropdown.send_key(new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		sleep 0.5

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)
		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		gene_sets.send_keys(gene_list_name)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# make sure editing the annotation works
	test 'front-end: user-annotation: editing' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# login
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		@driver.find_element(:class, "user-#{$random_seed}-edit").click
		wait_for_render(:id, 'user_annotation_name')

		# add 'new' to the name of annotation
		name = @driver.find_element(:id, 'user_annotation_name')
		name.send_key("new")

		# add 'new' to the labels
		annotation_labels = @driver.find_elements(:id, 'user-annotation_values')

		annotation_labels.each_with_index do |annot, i|
			annot.clear
			annot.send_keys("group#{i}new")
		end

		# update the annotation
		submit = @driver.find_element(:id, 'submit-button')
		submit.click

		wait_for_render(:class, 'annotation-name')

		# check names and labels
		new_names = @driver.find_elements(:class, 'annotation-name').map{|x| x.text }
		new_labels = @driver.find_elements(:class, "user-#{$random_seed}new").map{|x| x.text }

		# assert new name saved correctly
		assert (new_names.include? "user-#{$random_seed}new"), "Name edit failed, expected 'user-#{$random_seed}new' but got '#{new_names}'"

		# assert labels saved correctly
		assert (new_labels.include? "group0new"), "Name edit failed, expected 'new in group' but got '#{new_labels}'"
		close_modal('message_modal')

		# View the annotation
		@driver.find_element(:class, "user-#{$random_seed}new-show").click

		# assert the plot still renders
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# assert labels are correct
		plot_labels = @driver.find_elements(:class, "legendtext").map(&:text)
		assert (plot_labels.include? "user-#{$random_seed}new: group0new (3 points)"), "labels are incorrect: '#{plot_labels}' should include 'user-#{$random_seed}new: group0new'"

		# revert the annotation to old name and labels
		@driver.get annot_path
		@driver.find_element(:class, "user-#{$random_seed}new-edit").click
		wait_for_render(:id, 'user_annotation_name')

		# revert name
		name = @driver.find_element(:id, 'user_annotation_name')
		name.clear
		name.send_key("user-#{$random_seed}")

		# revert labels
		annotation_labels = @driver.find_elements(:id, 'user-annotation_values')

		annotation_labels.each_with_index do |annot, i|
			annot.clear
			annot.send_keys("group#{i}")
		end

		# update annotation
		submit = @driver.find_element(:id, 'submit-button')
		submit.click

		wait_for_render(:class, 'annotation-name')


		# check new names and labels
		new_names = @driver.find_elements(:class, 'annotation-name').map{|x| x.text }
		new_labels = @driver.find_elements(:class, "user-#{$random_seed}").map{|x| x.text }

		# assert new name saved correctly
		assert !(new_names.include? "user-#{$random_seed}new"), "Name edit failed, expected 'user-#{$random_seed}' but got '#{new_names}'"

		# assert labels saved correctly
		assert !(new_labels.include? "group0new"), "Name edit failed, did not expect 'new in group' but got '#{new_labels}'"

		close_modal('message_modal')

		# View the annotation
		@driver.find_element(:class, "user-#{$random_seed}-show").click

		# assert the plot still renders
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# assert labels are correct
		plot_labels = @driver.find_elements(:class, "legendtext").map(&:text)
		assert (plot_labels.include? "user-#{$random_seed}: group0 (3 points)"), "labels are incorrect: '#{plot_labels}' should include 'user-#{$random_seed}: group0'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# make sure sharing the annotation works
	test 'front-end: user-annotation: sharing' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# login
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		@driver.find_element(:class, "user-#{$random_seed}-exp-edit").click
		wait_for_render(:id, 'add-user-annotation-share')
		# click the share button
		share_button = @driver.find_element(:id, 'add-user-annotation-share')
		share_button.click

		share_email = @driver.find_element(:class, 'share-email')
		share_email.send_keys($share_email)

		share_permission = @driver.find_element(:class, 'share-permission')
		share_permission.send_keys('Edit')

		# update the annotation
		submit = @driver.find_element(:id, 'submit-button')
		submit.click
		close_modal('message_modal')

		# logout
		logout_from_portal

		# login
		login_as_other($test_email, $test_email_password)
		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		# View the annotation
		wait_until_page_loads(annot_path)
		@driver.find_element(:class, "user-#{$random_seed}-exp-show").click

		# make sure the new annotation still renders a plot for plotly
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# load random gene to search
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		wait_for_render(:id, 'perform-gene-search')
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# make sure the new annotation still renders plots for plotly
		assert element_present?(:id, 'box-controls'), 'could not find expression violin plot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		wait_for_render(:class, 'queried-gene')
		# confirm queried gene is the one returned
		queried_gene = @driver.find_element(:class, 'queried-gene')
		assert queried_gene.text == gene, "did not load the correct gene, expected #{gene} but found #{queried_gene.text}"

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		plot_dropdown = @driver.find_element(:id, 'plot_type')
		plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
		new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
		plot_dropdown.send_key(new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		sleep 0.5

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)
		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.last
		gene_list_name = list['value']
		gene_sets.send_keys(gene_list_name)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# revert the annotation to old name and labels
		@driver.get annot_path
		@driver.find_element(:class, "user-#{$random_seed}-exp-edit").click
		wait_for_render(:id, 'user_annotation_name')

		# change name
		name = @driver.find_element(:id, 'user_annotation_name')
		name.clear
		name.send_key("user-#{$random_seed}-exp-Share")

		# update annotation
		submit = @driver.find_element(:id, 'submit-button')
		submit.click

		wait_until_page_loads(annot_path)

		# check new names and labels
		new_names = @driver.find_elements(:class, 'annotation-name').map{|x| x.text }

		# assert new name saved correctly
		assert (new_names.include? "user-#{$random_seed}-exp-Share"), "Name edit failed, expected 'user-#{$random_seed}-exp-Share' but got '#{new_names}'"
		close_modal('message_modal')

		# View the annotation
		@driver.find_element(:class, "user-#{$random_seed}-exp-share-show").click

		# assert the plot still renders
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# assert labels are correct
		plot_labels = @driver.find_elements(:class, "legendtext").map(&:text)
		assert plot_labels.include?("user-#{$random_seed}-exp-Share: group0 (3 points)"), "labels are incorrect: '#{plot_labels}' should include 'user-#{$random_seed}-exp-Share: group0'"

		# logout
		logout_from_portal

		# login
		login_as_other($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		@driver.find_element(:class, "user-#{$random_seed}-exp-share-edit").click
		wait_for_render(:id, 'add-user-annotation-share')

		# click the share button
		share_button = @driver.find_element(:id, 'add-user-annotation-share')
		share_button.click

		share_email = @driver.find_element(:class, 'share-email')
		share_email.send_keys($share_email)

		share_permission = @driver.find_element(:class, 'share-permission')
		share_permission.send_keys('View')

		# change name
		name = @driver.find_element(:id, 'user_annotation_name')
		name.clear
		name.send_key("user-#{$random_seed}-exp")

		# update the annotation
		submit = @driver.find_element(:id, 'submit-button')
		submit.click
		wait_until_page_loads(annot_path)
		close_modal('message_modal')

		# logout
		logout_from_portal

		# login
		login_as_other($share_email, $share_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		# make sure can't edit
		editable = element_present?(:class, "user-#{$random_seed}-exp-edit")
		assert !editable, 'Edit button found'

		# View the annotation
		@driver.find_element(:class, "user-#{$random_seed}-exp-show").click

		# assert the plot still renders
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	test 'front-end: user-annotation: download annotation cluster file' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"
		login_path = @base_url + '/users/sign_in'
		# downloads require login now
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		# Click download and get filenames
		filename = (@driver.find_element(:class, "user-#{$random_seed}_cluster").attribute('innerHTML') + "_user-#{$random_seed}.txt").gsub(/ /, '_')
		basename = filename.split('.').first

		@driver.find_element(:class, "user-#{$random_seed}-download").click
		# give browser 5 seconds to initiate download
		sleep(5)
		# make sure file was actually downloaded
		file_exists = Dir.entries($download_dir).select {|f| f =~ /#{basename}/}.size >= 1 || File.exists?(File.join($download_dir, filename))
		assert file_exists, "did not find downloaded file: #{filename} in #{Dir.entries($download_dir).join(', ')}"

		# delete matching files
		Dir.glob("#{$download_dir}/*").select {|f| /#{basename}/.match(f)}.map {|f| File.delete(f)}

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# check user annotation publishing
	test 'front-end: user-annotation: publishing' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# login
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		num_annotations = @driver.find_elements(:class, 'annotation-name').length

		@driver.find_element(:class, "user-#{$random_seed}-publish").click
		accept_alert
		close_modal('message_modal')

		new_num_annotations = num_annotations
		i = 0
		while new_num_annotations >= num_annotations
			if i == 5
				assert false, "Reloaded the page five times but found #{new_num_annotations} rows instead of #{num_annotations-1} rows, indicating that the annotation was not deleted."
			end
			sleep 1.0
			@driver.get annot_path
			new_num_annotations = @driver.find_elements(:class, 'annotation-name').length
			i+=1
		end

		# check new names
		new_names = @driver.find_elements(:class, 'annotation-name').map{|x| x.text }

		# assert new name saved correctly
		assert !(new_names.include? "user-#{$random_seed}"), "Persist failed, expected no 'user-#{$random_seed}' but found it"

		# Wait for the annotation to persist
		sleep 3.0

		# go to study and make sure this annotation is saved
		two_d_study_path = @base_url + "/study/twod-study-#{$random_seed}"
		@driver.get two_d_study_path
		wait_until_page_loads(two_d_study_path)
		open_ui_tab('study-visualize')

		# choose the newly persisted annotation
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		annotation_dropdown = @driver.find_element(:id, 'annotation')
		annotation_dropdown.send_keys("user-#{$random_seed}")
		@wait.until {wait_for_plotly_render('#cluster-plot', 'rendered')}

		# make sure the new annotation still renders a plot for plotly
		annot_rendered = @driver.execute_script("return $('#cluster-plot').data('rendered')")
		assert annot_rendered, "cluster plot did not finish rendering on annotation change, expected true but found #{annot_rendered}"

		# load random gene to search
		gene = @genes.sample
		search_box = @driver.find_element(:id, 'search_genes')
		search_box.send_key(gene)
		search_genes = @driver.find_element(:id, 'perform-gene-search')
		search_genes.click

		# make sure the new annotation still renders plots for plotly
		assert element_present?(:id, 'box-controls'), 'could not find expression violin plot'
		assert element_present?(:id, 'scatter-plots'), 'could not find expression scatter plots'

		# confirm queried gene is the one returned
		queried_gene = @driver.find_element(:class, 'queried-gene')
		assert queried_gene.text == gene, "did not load the correct gene, expected #{gene} but found #{queried_gene.text}"

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		# change to box plot
		view_options_panel = @driver.find_element(:id, 'view-option-link')
		view_options_panel.click
		wait_for_render(:id, 'view-options')
		plot_dropdown = @driver.find_element(:id, 'plot_type')
		plot_ops = plot_dropdown.find_elements(:tag_name, 'option')
		new_plot = plot_ops.select {|opt| !opt.selected?}.sample.text
		plot_dropdown.send_key(new_plot)

		# wait until box plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		box_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert box_rendered, "box plot did not finish rendering, expected true but found #{box_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		search_menu = @driver.find_element(:id, 'search-omnibar-menu-icon')
		search_menu.click
		wait_for_render(:id, 'search_consensus')
		gene_list_panel = @driver.find_element(:id, 'gene-lists-link')
		gene_list_panel.click
		wait_for_render(:id, 'expression')
		sleep(1)
		gene_sets = @driver.find_element(:id, 'gene_set')
		opts = gene_sets.find_elements(:tag_name, 'option').delete_if {|o| o.text == 'Please select a gene list'}
		list = opts.sample['value']
		@driver.execute_script("$('expression-plots').data('box-rendered', false);")
		gene_sets.send_keys(list)
		assert element_present?(:id, 'expression-plots'), 'could not find box/scatter divs'
		sleep(1)

		# wait until violin plot renders, at this point all 3 should be done
		@wait.until {wait_for_plotly_render('#expression-plots', 'box-rendered')}
		violin_rendered = @driver.execute_script("return $('#expression-plots').data('box-rendered')")
		assert violin_rendered, "violin plot did not finish rendering, expected true but found #{violin_rendered}"
		scatter_rendered = @driver.execute_script("return $('#expression-plots').data('scatter-rendered')")
		assert scatter_rendered, "scatter plot did not finish rendering, expected true but found #{scatter_rendered}"
		reference_rendered = @driver.execute_script("return $('#expression-plots').data('reference-rendered')")
		assert reference_rendered, "reference plot did not finish rendering, expected true but found #{reference_rendered}"

		scroll_to(:top)
		open_ui_tab('study-download')

		download_button = @driver.find_element(:class, 'cluster-file')
		download_button.click

		# get the file contents
		contents = @driver.find_element(:tag_name, 'pre').text
		first_line = contents.split("\n").first.split.map(&:strip)
		%w[NAME X Y Sub-Group].each do |header|
			assert first_line.include?(header), "Original cluster's rows are absent, rows: #{first_line}, is missing #{header}"
		end
		assert (first_line.include?("user-#{$random_seed}")), "New annotation's rows are absent, rows: #{first_line}, missing: user-#{$random_seed}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# check user annotation deletion
	test 'front-end: user-annotation: deletion' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# login
		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		# load annotation panel
		annot_path = @base_url + '/user_annotations'
		@driver.get annot_path

		delete_btn = @driver.find_element(:class, "user-#{$random_seed}-exp-delete")
		delete_btn.click
		accept_alert
		close_modal('message_modal')

		#check new names
		first_row = @driver.find_element(:id, 'annotations').find_element(:tag_name, 'tbody').find_element(:tag_name, 'tr').find_element(:tag_name, 'td')
		unless first_row['class'] == 'dataTables_empty'
			#If you dont't have any annotations, they were all deleted
			new_names = @driver.find_elements(:class, 'annotation-name').map{|x| x.text }
			#assert new name saved correctly
			assert !(new_names.include? "user-#{$random_seed}-exp"), "Deletion failed, expected no 'user-#{$random_seed}-exp' but found it"
		end

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## WORKFLOW TESTS
	## Test FireCloud workflow integration
	##

	# test creating sample entities for workflows
	test 'front-end: workflows: import sample entities' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)

		open_ui_tab('study-workflows')
		wait_for_render(:id, 'workflow_identifier')
		samples_tab = @driver.find_element(:id, 'select-samples-nav')
		samples_tab.click
		wait_for_render(:id, 'submissions-table')
		# select all available fastq files to create a sample entity
		study_data_select = Selenium::WebDriver::Support::Select.new(@driver.find_element(:id, 'workflow_study_data'))
		study_data_select.select_all
		scroll_to(:bottom)
		save_samples = @driver.find_element(:id, 'save-workspace-samples')
		save_samples.click
		close_modal('message_modal')

		# test export button
		export_samples = @driver.find_element(:id, 'export-sample-info')
		export_samples.click
		# wait for export to complete
		sleep(3)
		filename = 'sample_info.txt'
		sample_info_file = File.open(File.join($download_dir, filename))
		assert File.exist?(sample_info_file.path), 'Did not find exported sample info file'
		file_contents = sample_info_file.readlines
		assert file_contents.size == 2, "Sample info file is wrong size; exprected 2 lines but found #{file_contents.size}"
		header_line = "entity:sample_id\tfastq_file_1\tfastq_file_2\tfastq_file_3\tfastq_file_4\n"
		assert file_contents.first == header_line, "sample info header line incorrect, expected #{header_line} but found '#{file_contents.first}'"
		assert file_contents.last.start_with?('cell_1'), "sample name in content line incorrect, expected 'cell_1' but found '#{file_contents.last}'"

		# clean up
		sample_info_file.close
		File.delete(File.join($download_dir, filename))

		# clear samples table
		clear_btn = @driver.find_element(:id, 'clear-sample-info')
		clear_btn.click

		# now select sample
		study_samples = Selenium::WebDriver::Support::Select.new(@driver.find_element(:id, 'workflow_samples'))
		study_samples.select_all
		# wait for table to populate (will have a row with sorting_1 class)
		@wait.until {@driver.find_element(:id, 'samples-table').find_element(:class, 'sorting_1').displayed?}

		# assert samples loaded correctly
		sample_table_body = @driver.find_element(:id, 'samples-table').find_element(:tag_name, 'tbody')
		sample_rows = sample_table_body.find_elements(:tag_name, 'tr')
		assert sample_rows.size == 1, "Did not find correct number of samples in table, expected 1 but found '#{sample_rows.size}'"
		sample_name = sample_rows.first.find_element(:tag_name, 'td')
		assert sample_name.text == 'cell_1', "Did not find correct sample name, expected 'cell_1' but found '#{sample_name.text}'"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test creating & cancelling submissions of workflows
	test 'front-end: workflows: launch and cancel submissions' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)

		# select worfklow & sample
		open_ui_tab('study-workflows')
		wait_for_render(:id, 'workflow_identifier')
		scroll_to(:bottom)
		wdl_workdropdown = @driver.find_element(:id, 'workflow_identifier')
		wdl_workflows = wdl_workdropdown.find_elements(:tag_name, 'option')
		wdl_workflows.last.click

		samples_tab = @driver.find_element(:id, 'select-samples-nav')
		samples_tab.click
		wait_for_render(:id, 'submissions-table')

		study_samples = Selenium::WebDriver::Support::Select.new(@driver.find_element(:id, 'workflow_samples'))
		study_samples.select_all
		# wait for table to populate (will have a row with sorting_1 class)
		@wait.until {@driver.find_element(:id, 'samples-table').find_element(:class, 'sorting_1').displayed?}

		# submit workflow
		review_tab = @driver.find_element(:id, 'review-submission-nav')
		review_tab.click
		wait_for_render(:id, 'submit-workflow')
		submit_btn = @driver.find_element(id: 'submit-workflow')
		submit_btn.click
		close_modal('generic-update-modal')

		# abort workflow
		scroll_to(:top)
		abort_btn = @driver.find_element(:class, 'abort-submission')
		abort_btn.click
		accept_alert
		wait_for_modal_open('generic-update-modal')
		expected_conf = 'Submission Successfully Cancelled'
		confirmation = @driver.find_element(:id, 'generic-update-modal-title').text
		assert confirmation == expected_conf, "Did not find correct confirmation message, expected '#{expected_conf}' but found '#{confirmation}'"
		close_modal('generic-update-modal')

		# submit new workflow
		submit_btn = @driver.find_element(id: 'submit-workflow')
		submit_btn.click
		close_modal('generic-update-modal')

		# force a refresh of the table
		scroll_to(:top)
		refresh_btn = @driver.find_element(:id, 'refresh-submissions-table-top')
		refresh_btn.click
		sleep(3)

		# assert there are two workflows, one aborted and one submitted
		submissions_table = @driver.find_element(:id, 'submissions-table')
		submissions = submissions_table.find_element(:tag_name, 'tbody').find_elements(:tag_name, 'tr')
		assert submissions.size >= 2, "Did not find correct number of submissions, expected at least 2 but found #{submissions.size}"
		submissions.each do |submission|
			submission_id = submission['id']
			submission_state = @driver.find_element(:id, "submission-#{submission_id}-state").text
			submission_status = @driver.find_element(:id, "submission-#{submission_id}-status").text
			if %w(Aborting Aborted).include?(submission_state)
				assert %w(Queued Submitted Failed Aborting Aborted).include?(submission_status), "Found incorrect submissions status for aborted submission #{submission_id}: #{submission_status}"
			else
				assert %w(Queued Submitted Launching Running Succeeded).include?(submission_status), "Found incorrect submissions status for regular submission #{submission_id}: #{submission_status}"
			end
		end
		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test syncing outputs from submission
	test 'front-end: workflows: sync outputs' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)
		open_ui_tab('study-workflows')
		wait_for_render(:id, 'submissions-table')

		# make sure submission has completed
		submissions_table = @driver.find_element(:id, 'submissions-table')
		submissions = submissions_table.find_element(:tag_name, 'tbody').find_elements(:tag_name, 'tr')
		completed_submission = submissions.find {|sub|
			sub.find_element(:class, "submission-state").text == 'Done' &&
					sub.find_element(:class, "submission-status").text == 'Succeeded'
		}
		i = 1
		while completed_submission.nil?
			omit_if i >= 60, 'Skipping test; waited 5 minutes but no submissions complete yet.'

			$verbose ? puts("no completed submissions, refresh try ##{i}") : nil
			refresh_btn = @driver.find_element(:id, 'refresh-submissions-table-top')
			refresh_btn.click
			sleep 5
			submissions_table = @driver.find_element(:id, 'submissions-table')
			submissions = submissions_table.find_element(:tag_name, 'tbody').find_elements(:tag_name, 'tr')
			completed_submission = submissions.find {|sub|
				sub.find_element(:class, "submission-state").text == 'Done' &&
						sub.find_element(:class, "submission-status").text == 'Succeeded'
			}
			i += 1
		end

		# download an output file
		# outputs_btn = completed_submission.find_element(:class, 'get-submission-outputs')
		# outputs_btn.click
		# wait_for_render(:class, 'submission-output')
		# output_download = @driver.find_element(:class, 'submission-output')
		# filename = output_download['download']
		# output_download.click
		# # give the app a few seconds to initiate download request
		# sleep(5)
		# output_file = File.open(File.join($download_dir, filename))
		# assert File.exist?(output_file.path), 'Did not find downloaded submission output file'
		# File.delete(File.join($download_dir, filename))
		# close_modal('generic-update-modal')

		# sync an output file
		sync_btn = completed_submission.find_element(:class, 'sync-submission-outputs')
		sync_btn.click
		wait_for_render(:class, 'unsynced-study-file')
		study_file_forms = @driver.find_elements(:class, 'unsynced-study-file')
		study_file_forms.each do |form|
			file_type = form.find_element(:id, 'study_file_file_type')
			file_type.send_keys('Other')
			sync_button = form.find_element(:class, 'save-study-file')
			sync_button.click
			close_modal('sync-notice-modal')
		end
		scroll_to(:bottom)
		synced_toggle = @driver.find_element(:id, 'synced-data-panel-toggle')
		synced_toggle.click
		wait_for_render(:class, 'synced-study-file')
		synced_files = @driver.find_elements(:class, 'synced-study-file')
		filenames = synced_files.map {|form| form.find_element(:class, 'filename')[:value]}
		assert filenames.any?, "Did not find any files in list of synced files: #{filenames.join(', ')}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# view/export metadata from a submission
	test 'front-end: workflows: export metadata' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)
		open_ui_tab('study-workflows')
		wait_for_render(:id, 'submissions-table')

		# find a completed submission
		submissions_table = @driver.find_element(:id, 'submissions-table')
		submissions = submissions_table.find_element(:tag_name, 'tbody').find_elements(:tag_name, 'tr')
		completed_submission = submissions.find {|sub|
			sub.find_element(:class, "submission-state").text == 'Done' &&
					sub.find_element(:class, "submission-status").text == 'Succeeded'
		}

		omit_if completed_submission.nil?, 'Skipping test; No completed submissions'

		# view run metadata
		view_btn = completed_submission.find_element(:class, 'view-submission-metadata')
		view_btn.click
		wait_for_modal_open('generic-update-modal')

		# export analysis.json file
		export_btn = @driver.find_element(:class, 'export-submission-metadata')
		export_btn.click
		sleep(1)
		filename = 'analysis.json'
		filepath = File.join($download_dir, filename)
		assert File.exist?(filepath), "Did not find exported analysis metadata at #{filepath}"

		# make sure exported file is valid by checking for some expected keys
		analysis_file = File.open(filepath)
		analysis_json = JSON.parse(analysis_file.read)
		assert %w(inputs outputs name tasks analysis_id).all? {|k| analysis_json.has_key?(k)}, "Exported analysis file does not have required keys: #{analysis_json.keys}"

		# clean up
		File.delete(filepath)

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# delete submissions from study
	test 'front-end: workflows: delete submissions' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)
		open_ui_tab('study-workflows')
		wait_for_render(:id, 'submissions-table')
		submissions_table = @driver.find_element(:id, 'submissions-table')
		submission_ids = submissions_table.find_element(:tag_name, 'tbody').find_elements(:tag_name, 'tr').map {|s| s['id']}.delete_if {|id| id.empty?}
		submission_ids.each do |submission_id|
			submission = @driver.find_element(:id, submission_id)
			delete_btn = submission.find_element(:class, 'delete-submission-files')
			delete_btn.click
			accept_alert
			close_modal('generic-update-modal')
			# let table refresh complete
			sleep(3)
		end
		empty_table = @driver.find_element(:id, 'submissions-table')
		empty_row = empty_table.find_element(:tag_name, 'tbody').find_element(:tag_name, 'tr').find_element(:tag_name, 'td')
		assert empty_row.text == 'No data available in table', "Did not completely remove all submissions, expected 'No data available in table' but found #{empty_row.text}"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	# test deleting sample entities for workflows
	test 'front-end: workflows: delete sample entities' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		login_path = @base_url + '/users/sign_in'
		@driver.get login_path
		wait_until_page_loads(login_path)
		login($test_email, $test_email_password)

		study_page = @base_url + "/study/test-study-#{$random_seed}"
		@driver.get study_page
		wait_until_page_loads(study_page)

		open_ui_tab('study-workflows')
		wait_for_render(:id, 'workflow_identifier')
		samples_tab = @driver.find_element(:id, 'select-samples-nav')
		samples_tab.click
		wait_for_render(:id, 'submissions-table')

		# now select sample
		study_samples = Selenium::WebDriver::Support::Select.new(@driver.find_element(:id, 'workflow_samples'))
		study_samples.select_all
		# wait for table to populate (will have a row with sorting_1 class)
		@wait.until {@driver.find_element(:id, 'samples-table').find_element(:class, 'sorting_1').displayed?}

		# delete samples
		delete_btn = @driver.find_element(:id, 'delete-workspace-samples')
		delete_btn.click
		close_modal('message_modal')

		empty_table = @driver.find_element(:id, 'samples-table')
		empty_row = empty_table.find_element(:tag_name, 'tbody').find_element(:tag_name, 'tr').find_element(:tag_name, 'td')
		assert empty_row.text == 'No data available in table', "Did not completely remove all samples, expected 'No data available in table' but found #{empty_row.text}"
		samples_list = @driver.find_element(:id, 'workflow_samples')
		assert samples_list['value'].empty?, "Did not delete workspace samples; samples list is not empty: ''#{samples_list['value']}''"

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end

	##
	## CLEANUP
	## Delete all studies created during the regrssion suite
	##

	test 'cleanup: delete all test studies' do
		puts "#{File.basename(__FILE__)}: '#{self.method_name}'"

		# log in first
		path = @base_url + '/studies'
		@driver.get path
		close_modal('message_modal')
		login($test_email, $test_email_password)

		study_keys = [
				"test-study-#{$random_seed}-delete",
				"private-study-#{$random_seed}-delete",
				"gzip-parse-#{$random_seed}-delete",
				"embargo-study-#{$random_seed}-delete",
				"twod-study-#{$random_seed}-delete",
				"new-project-study-#{$random_seed}-delete",
				"sync-test-#{$random_seed}-delete-local"
		]

		# delete studies
		study_keys.each do |study_key|
			if element_present?(:class, study_key)
				@driver.find_element(:class, study_key).click
				accept_alert
				close_modal('message_modal')
			end
		end

		puts "#{File.basename(__FILE__)}: '#{self.method_name}' successful!"
	end
end