login() {
  local account_id
  local region
  
  account_id=$(aws sts get-caller-identity --query Account --output text)
  region=$(get_ecr_region)

  aws ecr get-login-password \
    --region "${region}" \
    | docker login \
    --username AWS \
    --password-stdin "${account_id}.dkr.ecr.${region}.amazonaws.com"
}

get_ecr_region() {
  echo "${BUILDKITE_PLUGIN_DOCKER_ECR_CACHE_REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"
}

get_registry_url() {
  local repository_name
  repository_name="$(get_ecr_repository_name)"
  aws ecr describe-repositories \
    --repository-names "${repository_name}" \
    --output text \
    --query 'repositories[0].repositoryUri'
}

ecr_exists() {
  local repository_name="${1}"
  aws ecr describe-repositories \
    --repository-names "${repository_name}" \
    --output text \
    --query 'repositories[0].registryId'
}

image_exists() {
  local repository_name="$(get_ecr_repository_name)"
  local image_tag="${1}"
  local image_meta="$(aws ecr list-images \
    --repository-name "${repository_name}" \
    --query "imageIds[?imageTag=='${image_tag}'].imageTag" \
    --output text)"
  
  if [ $image_meta == $image_tag ]; then
    return 1
  else
    return 0
  fi
}

get_ecr_arn() {
  local repository_name="${1}"
  aws ecr describe-repositories \
    --repository-names "${repository_name}" \
    --output text \
    --query 'repositories[0].repositoryArn'
}

get_ecr_tags() {
local result=$(cat <<EOF
{
    "tags": []
}
EOF
)
  while IFS='=' read -r name _ ; do
    if [[ $name =~ ^(BUILDKITE_PLUGIN_DOCKER_ECR_CACHE_ECR_TAGS_) ]] ; then
      # Handle plain key=value, e.g
      # ecr-tags:
      #   KEY_NAME: 'key-value'
      key_name=$(echo "${name}" | sed 's/^BUILDKITE_PLUGIN_DOCKER_ECR_CACHE_ECR_TAGS_//')
      key_value=$(env | grep "$name" | sed "s/^$name=//")
      result=$(echo $result | jq ".tags[.tags| length] |= . + {\"Key\": \"${key_name}\", \"Value\": \"${key_value}\"}")
    fi
  done < <(env | sort)

  echo $result
}

get_ecr_repository_name() {
  echo "${BUILDKITE_PLUGIN_DOCKER_ECR_CACHE_ECR_NAME:-"$(get_default_image_name)"}"
}

configure_registry_for_image_if_necessary() {
  local repository_name
  repository_name="$(get_ecr_repository_name)"
  local max_age_days="${BUILDKITE_PLUGIN_DOCKER_ECR_CACHE_MAX_AGE_DAYS:-30}"
  local ecr_tags="$(get_ecr_tags)"
  local num_tags=$(echo $ecr_tags | jq '.tags | length')

  if ! ecr_exists "${repository_name}"; then
    aws ecr create-repository --repository-name "${repository_name}" --cli-input-json "${ecr_tags}"
  else
    if [ "$num_tags" -gt 0 ]; then
      local ecr_arn=$(get_ecr_arn "${repository_name}")
      aws ecr tag-resource --resource-arn ${ecr_arn} --cli-input-json "${ecr_tags}"
    fi
  fi

  # As of May 2019 ECR lifecycle policies can only have one rule that targets "any"
  # Due to this limitation, only the max_age policy is applied
  policy_text=$(cat <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire images older than ${max_age_days} days",
      "selection": {
        "tagStatus": "any",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": ${max_age_days}
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
EOF
)

  # Always set the lifecycle policy to update repositories automatically
  # created before PR #9.
  #
  # When using a custom repository with a restricted Buildkite role this might
  # not succeed. Ignore the error and let the build continue.
  aws ecr put-lifecycle-policy \
  --repository-name "${repository_name}" \
  --lifecycle-policy-text "${policy_text}" || true
}
