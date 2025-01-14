#!/usr/bin/env bash

# script that is called when booting portal in test environment to run all unit tests in the correct order as some
# tests change downstream behavior after they've run
#
# can take the following arguments:
#
# -t filepath    Run all tests in the specified file
# -R regex      Run all matching tests in the file specified with -t

while getopts "t:R:" OPTION; do
case $OPTION in
  t)
    TEST_FILEPATH="$OPTARG"
    ;;
  R)
    MATCHING_TESTS="$OPTARG"
    ;;
  esac
done
start=$(date +%s)
RETURN_CODE=0
FAILED_COUNT=0
echo "Precompiling assets, yarn and webpacker..."
RAILS_ENV=test NODE_ENV=test bin/bundle exec rake assets:clean
RAILS_ENV=test NODE_ENV=test bin/bundle exec rake assets:precompile
echo "Seeding test database..."
bundle exec rake RAILS_ENV=test db:seed
echo "Database initialized, generating random test seed..."
RANDOM_SEED=`openssl rand -hex 16`
echo $RANDOM_SEED > /home/app/webapp/.random_seed
echo "Launching tests using seed: $RANDOM_SEED"
if [ "$TEST_FILEPATH" != "" ]
then
  if [ "$MATCHING_TESTS" != "" ]
  then
    EXTRA_ARGS="-n $MATCHING_TESTS"
  fi
  echo "Running specified tests: $TEST_FILEPATH $EXTRA_ARGS"
  bundle exec ruby -I test $TEST_FILEPATH $EXTRA_ARGS
  code=$? # immediately capture exit code to prevent this from getting clobbered
  if [[ $code -ne 0 ]]; then
    RETURN_CODE=$code
    ((FAILED_COUNT++))
  fi
else
  echo "Running all unit & integration tests..."
  declare -a tests=(test/integration/fire_cloud_client_test.rb
                    test/integration/cache_management_test.rb
                    test/integration/tos_acceptance_test.rb
                    test/integration/study_creation_test.rb
                    test/integration/study_validation_test.rb
                    test/integration/taxons_controller_test.rb
                    test/controllers/analysis_configurations_controller_test.rb
                    test/controllers/site_controller_test.rb
                    test/api/site_controller_test.rb
                    test/api/studies_controller_test.rb
                    test/api/study_files_controller_test.rb
                    test/api/study_file_bundles_controller_test.rb
                    test/api/study_shares_controller_test.rb
                    test/api/directory_listings_controller_test.rb
                    test/models/cluster_group_test.rb
                    test/models/user_annotation_test.rb
                    test/models/parse_utils_test.rb
                    test/models/analysis_configuration_test.rb
  )
  for test_name in ${tests[*]}; do
      bundle exec ruby -I test $test_name
      code=$? # immediately capture exit code to prevent this from getting clobbered
      if [[ $code -ne 0 ]]; then
        RETURN_CODE=$code
        ((FAILED_COUNT++))
      fi
  done
fi
echo "Cleaning up..."
bundle exec bin/rails runner -e test "Study.destroy_all" # destroy all studies to clean up any files
bundle exec rake RAILS_ENV=test db:purge
echo "Cleanup complete!"
end=$(date +%s)
difference=$(($end - $start))
min=$(($difference / 60))
sec=$(($difference % 60))
echo "Total elapsed time: $min minutes, $sec seconds"
if [[ $RETURN_CODE -ne 0 ]]; then
	printf "\n### There were $FAILED_COUNT errors/failed test suites in this run ###\n\n"
fi
echo "Exiting with code: $RETURN_CODE"
exit $RETURN_CODE