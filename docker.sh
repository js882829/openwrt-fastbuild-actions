#!/usr/bin/env bash

set -eo pipefail

# helper functions
_exit_if_empty() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "Missing input $var_name" >&2
    exit 1
  fi
}

_get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
    sort -n |
    tail -n 1
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_full_image_name() {
  echo ${REGISTRY:+$REGISTRY/}${IMAGE_NAME}
}

# action steps
check_required_input() {
  _exit_if_empty USERNAME "${USERNAME}"
  _exit_if_empty PASSWORD "${PASSWORD}"
  _exit_if_empty IMAGE_NAME "${IMAGE_NAME}"
  _exit_if_empty IMAGE_TAG "${IMAGE_TAG}"
  _exit_if_empty CONTEXT "${CONTEXT}"
  _exit_if_empty DOCKERFILE "${DOCKERFILE}"
  _exit_if_empty PULL_STAGES_LOG "${PULL_STAGES_LOG}"
  _exit_if_empty BUILD_LOG "${BUILD_LOG}"
}

login_to_registry() {
  echo "${PASSWORD}" | docker login -u "${USERNAME}" --password-stdin "${REGISTRY}"
}

pull_cached_stages() {
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  build_target=()
  if [ ! -z "${1}" ]; then
    build_target+=(--target "${1}")
  fi
  build_args=()
  if [ ! -z "${BUILD_ARGS}" ]; then
    IFS_ORI="$IFS"
    IFS=$'\x20'
    
    for arg in ${BUILD_ARGS[@]};
    do
      build_args+=(--build-arg "${arg}=${!arg}")
    done
    IFS="$IFS_ORI"
  fi

  # build image using cache
  DOCKER_BUILDKIT=1 docker build \
    "${build_target[@]}" \
    "${build_args[@]}" \
    $cache_from \
    --build-arg BUILDKIT_INLINE_CACHE=1 \
    --tag "$(_get_full_image_name)":${IMAGE_TAG} \
    --file ${CONTEXT}/${DOCKERFILE} \
    ${CONTEXT} | tee "$BUILD_LOG"
}

mount_container() {
  docker container create --name builder -v $1:$2 "$(_get_full_image_name)":${IMAGE_TAG}
}

push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0
  local git_tag=${GITHUB_REF##*/tags/}
  local image_with_git_tag
  image_with_git_tag="$(_get_full_image_name)":$git_tag
  docker tag "$(_get_full_image_name)":${IMAGE_TAG} "$image_with_git_tag"
  docker push "$image_with_git_tag"
}

push_image_and_stages() {
  # push image
  docker push "$(_get_full_image_name)":${IMAGE_TAG}
  push_git_tag

  # push each building stage
  stage_number=1
  for stage in $(_get_stages); do
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag "$(_get_full_image_name)":${IMAGE_TAG} $stage_image
  docker push $stage_image
}

logout_from_registry() {
  docker logout "${REGISTRY}"
}

check_required_input
# login_to_registry
# pull_cached_stages
# build_image

# if [ "$PUSH_IMAGE_AND_STAGES" = true ]; then
#   push_image_and_stages
# fi

# logout_from_registry
