#!/bin/bash

set -ex

function stripColors {
  echo "${1}" | sed 's/\x1b\[[0-9;]*m//g'
}

function hasPrefix {
  case ${2} in
    "${1}"*)
      true
      ;;
    *)
      false
      ;;
  esac
}

function getChangedDirectoriesJson {
  prFilesUrl="$(cat ${GITHUB_EVENT_PATH} | jq -r '.pull_request._links.self.href')/files"
  changedDirectories=
  while [ "${prFilesUrl}" != "" ]; do
    changedDirectories="$(printf "${changedDirectories}\n$(curl -fSsL -H "Authorization: token ${GITHUB_TOKEN}" "${prFilesUrl}" | jq -cMr '.[].filename' | awk '/\// { sub(/\/?[^\/]+$/, "", $0); print "\"" $0 "\"" }')\n" | sort | uniq)"
    responseHeaders="$(curl -IfSsL -H "Authorization: token ${GITHUB_TOKEN}" "${prFilesUrl}" | sed -ne '/^Link/p')"
    prFilesUrl="$(echo "${responseHeaders}" | sed -Ene '/^Link:/ s/^.*\<([^\>]+)\>\; rel="next".*$/\1/gp')"
  done
  echo "${changedDirectories}" | jq -rscM 'unique'
}

function parseInputs {
  # Required inputs
  if [ "${INPUT_TF_ACTIONS_VERSION}" != "" ]; then
    tfVersion=${INPUT_TF_ACTIONS_VERSION}
  else
    echo "Input terraform_version cannot be empty"
    exit 1
  fi

  if [ "${INPUT_TF_ACTIONS_SUBCOMMAND}" != "" ]; then
    tfSubcommand=${INPUT_TF_ACTIONS_SUBCOMMAND}
  else
    echo "Input terraform_subcommand cannot be empty"
    exit 1
  fi

  tfComment=0
  if [ "${INPUT_TF_ACTIONS_COMMENT}" == "1" ] || [ "${INPUT_TF_ACTIONS_COMMENT}" == "true" ]; then
    tfComment=1
  fi

  tfCLICredentialsHostname=""
  if [ "${INPUT_TF_ACTIONS_CLI_CREDENTIALS_HOSTNAME}" != "" ]; then
    tfCLICredentialsHostname=${INPUT_TF_ACTIONS_CLI_CREDENTIALS_HOSTNAME}
  fi

  tfCLICredentialsToken=""
  if [ "${INPUT_TF_ACTIONS_CLI_CREDENTIALS_TOKEN}" != "" ]; then
    tfCLICredentialsToken=${INPUT_TF_ACTIONS_CLI_CREDENTIALS_TOKEN}
  fi
}

function configureCLICredentials {
  if [[ ! -f "${HOME}/.terraformrc" ]] && [[ "${tfCLICredentialsToken}" != "" ]]; then
    cat > ${HOME}/.terraformrc << EOF
credentials "${tfCLICredentialsHostname}" {
  token = "${tfCLICredentialsToken}"
}
EOF
  fi
}

function installTerraform {
  if [[ "${tfVersion}" == "latest" ]]; then
    echo "Checking the latest version of Terraform"
    tfVersion=$(curl -sL https://releases.hashicorp.com/terraform/index.json | jq -r '.versions[].version' | grep -v '[-].*' | sort -rV | head -n 1)

    if [[ -z "${tfVersion}" ]]; then
      echo "Failed to fetch the latest version"
      exit 1
    fi
  fi

  url="https://releases.hashicorp.com/terraform/${tfVersion}/terraform_${tfVersion}_linux_amd64.zip"

  echo "Downloading Terraform v${tfVersion}"
  curl -s -S -L -o /tmp/terraform_${tfVersion} ${url}
  if [ "${?}" -ne 0 ]; then
    echo "Failed to download Terraform v${tfVersion}"
    exit 1
  fi
  echo "Successfully downloaded Terraform v${tfVersion}"

  echo "Unzipping Terraform v${tfVersion}"
  unzip -d /usr/local/bin /tmp/terraform_${tfVersion} &> /dev/null
  if [ "${?}" -ne 0 ]; then
    echo "Failed to unzip Terraform v${tfVersion}"
    exit 1
  fi
  echo "Successfully unzipped Terraform v${tfVersion}"
}

function main {
  # Source the other files to gain access to their functions
  scriptDir=$(dirname ${0})
  source ${scriptDir}/terraform_fmt.sh
  source ${scriptDir}/terraform_init.sh
  source ${scriptDir}/terraform_validate.sh
  source ${scriptDir}/terraform_plan.sh
  source ${scriptDir}/terraform_apply.sh
  source ${scriptDir}/terraform_output.sh
  source ${scriptDir}/terraform_import.sh
  source ${scriptDir}/terraform_taint.sh

  parseInputs
  tfChangedPaths="$(getChangedDirectoriesJson)"
  configureCLICredentials
  installTerraform

  for changedPath in $(echo "${tfChangedPaths}" | jq '.[] | @base64'); do
    _jq() {
     echo "${changedPath}" | base64 -d
    }

    if [ -e "$(_jq)/backend.tf" ]; then
      case "${tfSubcommand}" in
        fmt)
          (cd "$(_jq)" && terraformFmt)
          ;;
        init)
          (cd "$(_jq)" && terraformInit)
          ;;
        validate)
          (cd "$(_jq)" && terraformValidate)
          ;;
        plan)
          (cd "$(_jq)" && terraformPlan)
          ;;
        apply)
          (cd "$(_jq)" && terraformApply)
          ;;
        output)
          (cd "$(_jq)" && terraformOutput)
          ;;
        import)
          (cd "$(_jq)" && terraformImport)
          ;;
        taint)
          (cd "$(_jq)" && terraformTaint)
          ;;
        *)
          echo "Error: Must provide a valid value for terraform_subcommand"
          exit 1
          ;;
      esac
    else
      echo "INFO No Terraform module found at $(_jq)" >&2
    fi
  done
}

main
