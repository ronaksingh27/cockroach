# FYI: You can run `./dev builder` to run this Docker image. :)
# `dev` depends on this variable! Don't change the name or format unless you
# also update `dev` accordingly.
BAZEL_IMAGE=cockroachdb/bazel:20220328-163955

# Call `run_bazel $NAME_OF_SCRIPT` to start an appropriately-configured Docker
# container with the `cockroachdb/bazel` image running the given script.
# BAZEL_SUPPORT_EXTRA_DOCKER_ARGS will be passed on to `docker run` unchanged.
run_bazel() {
    if [ -z "${root:-}" ]
    then
        echo '$root is not set; please source teamcity-support.sh'
        exit 1
    fi

    # Set up volumes.
    # TeamCity uses git alternates, so make sure we mount the path to the real
    # git objects.
    teamcity_alternates="/home/agent/system/git"
    vols="--volume ${teamcity_alternates}:${teamcity_alternates}:ro"
    artifacts_dir=$root/artifacts
    mkdir -p "$artifacts_dir"
    vols="${vols} --volume ${artifacts_dir}:/artifacts"
    cache=/home/agent/.bzlhome
    mkdir -p $cache
    vols="${vols} --volume ${root}:/go/src/github.com/cockroachdb/cockroach"
    vols="${vols} --volume ${cache}:/home/roach"

    docker run -i ${tty-} --rm --init \
        -u "$(id -u):$(id -g)" \
        --workdir="/go/src/github.com/cockroachdb/cockroach" \
	${BAZEL_SUPPORT_EXTRA_DOCKER_ARGS:+$BAZEL_SUPPORT_EXTRA_DOCKER_ARGS} \
        ${vols} \
        $BAZEL_IMAGE "$@"
}

# local copy of _tc_build_branch from teamcity-support.sh to avoid imports.
_tc_build_branch() {
    echo "${TC_BUILD_BRANCH#refs/heads/}"
}

# local copy of tc_release_branch from teamcity-support.sh to avoid imports.
_tc_release_branch() {
  branch=$(_tc_build_branch)
  [[ "$branch" == master || "$branch" == release-* || "$branch" == provisional_* ]]
}

# process_test_json processes logs and submits failures to GitHub
# Requires GITHUB_API_TOKEN set for the release branches.
# Accepts 5 arguments:
# testfilter: path to the `testfilter` executable, usually
#   `$BAZEL_BIN/pkg/cmd/testfilter/testfilter_/testfilter`
# github_post: path to the `github-post` executable, usually
#   `$BAZEL_BIN/pkg/cmd/github-post/github-post_/github-post`
# artifacts_dir: usually `/artifacts`
# test_json: path to test's JSON output, usually generated by `rules_go`'s and
#   `GO_TEST_JSON_OUTPUT_FILE`.
# create_tarball: whether to create a tarball with full logs. If the test's
#   exit code is passed, the tarball is generated on failures.
#
# The variable BAZEL_SUPPORT_EXTRA_GITHUB_POST_ARGS can be set to add extra
# arguments to $github_post.
process_test_json() {
  local testfilter=$1
  local github_post=$2
  local artifacts_dir=$3
  local test_json=$4
  local create_tarball=$5

  $testfilter -mode=strip < "$test_json" | $testfilter -mode=omit | $testfilter -mode=convert > "$artifacts_dir"/failures.txt
  failures_size=$(stat --format=%s "$artifacts_dir"/failures.txt)
  if [ $failures_size = 0 ]; then
    rm -f "$artifacts_dir"/failures.txt
  fi

  if _tc_release_branch; then
    if [ -z "${GITHUB_API_TOKEN-}" ]; then
      # GITHUB_API_TOKEN must be in the env or github-post will barf if it's
      # ever asked to post, so enforce that on all runs.
      # The way this env var is made available here is quite tricky. The build
      # calling this method is usually a build that is invoked from PRs, so it
      # can't have secrets available to it (for the PR could modify
      # build/teamcity-* to leak the secret). Instead, we provide the secrets
      # to a higher-level job (Publish Bleeding Edge) and use TeamCity magic to
      # pass that env var through when it's there. This means we won't have the
      # env var on PR builds, but we'll have it for builds that are triggered
      # from the release branches.
      echo "GITHUB_API_TOKEN must be set"
      exit 1
    else
      $github_post ${BAZEL_SUPPORT_EXTRA_GITHUB_POST_ARGS:+$BAZEL_SUPPORT_EXTRA_GITHUB_POST_ARGS} < "$test_json"
    fi
  fi

  if [ "$create_tarball" -ne 0 ]; then
    # Keep the debug file around for failed builds. Compress it to avoid
    # clogging the agents with stuff we'll hopefully rarely ever need to
    # look at.
    # If the process failed, also save the full human-readable output. This is
    # helpful in cases in which tests timed out, where it's difficult to blame
    # the failure on any particular test. It's also a good alternative to poking
    # around in test.json.txt itself when anything else we don't handle well happens,
    # whatever that may be.
    $testfilter -mode=convert < "$test_json" > "$artifacts_dir"/full_output.txt
    (cd "$artifacts_dir" && tar --strip-components 1 -czf full_output.tgz full_output.txt $(basename $test_json))
    rm -rf "$artifacts_dir"/full_output.txt
  fi

  # Some unit tests test automatic ballast creation. These ballasts can be
  # larger than the maximum artifact size. Remove any artifacts with the
  # EMERGENCY_BALLAST filename.
  find "$artifacts_dir" -name "EMERGENCY_BALLAST" -delete
}

