#!/bin/sh
# shellcheck disable=SC2016

# ----- Global Config -----

INIT_RESPONSE_JSON_PATH="$(pwd)/init-response.json" # file containing unseal and root keys


# ----- Functions -----

### General Helpers

check_dependencies() {
	# Usage: check_dependencies

	if ! (docker-compose --help \
		&& jq --help \
		&& gpg --help) > /dev/null 2>&1
	then
		echo 'ERROR: you are missing dependencies'
		echo 'docker-compose, jq, need to be installed and accessible via the PATH'
		return 1
	fi
}

service_is_healthy() {
	# Usage: service_is_healthy <SERVICE>

	SERVICE_HEALTH="$(docker-compose ps --format json "${1}" 2> /dev/null \
		| jq -r '.[0].Health' \
		| tr -d '"')"

	[ "${SERVICE_HEALTH}" = 'healthy' ]
}

current_timestamp() {
	# Usage: current_timestamp

	date '+%s'
}


### GPG

gpg_key_exists() {
	# Usage: gpg_key_exists <KEY_ID>

	gpg --list-keys "${1}" > /dev/null 2>&1
}

validate_gpg_key_for_unsealing() {
	# Usage: validate_gpg_key_for_unsealing <KEY_ID>

	GPG_KEY_ID="${1}"

	if [ -z "${GPG_KEY_ID}" ]
	then
		echo 'ERROR: no GPG key ID provided'
		echo 'You probably need to set the environment variable UNSEAL_GPG_KEY_ID'
		echo 'Using the ID of your public key of choice, run: `export UNSEAL_GPG_KEY_ID=<gpg-public-key-id>`'
		return 1

	elif ! gpg_key_exists "${GPG_KEY_ID}"
	then
		echo "ERROR: GPG key with ID '${GPG_KEY_ID}' is not known"
		echo 'Import a public key from a file: `gpg --import <PATH_TO_FILE>`'
		echo 'Import a public key from your clipboard: `xclip -o | gpg --import`'
		return 1
	fi
}

gpg_export_public_key_to_base64() {
	# Usage: gpg_export_public_key_to_base64 <KEY_ID>

	GPG_KEY_ID="${1}"

	if ! gpg_key_exists "${GPG_KEY_ID}"
	then
		echo "ERROR: GPG key with ID '${GPG_KEY_ID} is not known'"
		echo 'Import a public key from a file: `gpg --import <PATH_TO_FILE>`'
		echo 'Import a public key from your clipboard: `xclip -o | gpg --import`'
		return 1
	fi

	gpg --export "${GPG_KEY_ID}" | base64 | tr -d '\n' # `base64 --wrap=0` is not portable
}

gpg_decrypt_base64() {
	# Usage: gpg_decrypt_base64 <BASE64-ENCODED_CIPHERTEXT>

	B64_CIPHERTEXT="${1}"

	if ! printf '%s' "${B64_CIPHERTEXT}" | base64 -d > /dev/null 2>&1
	then
		echo 'ERROR: ciphertext input is not base64-encoded'
		return 1
	fi

	if ! printf '%s' "${B64_CIPHERTEXT}" | base64 -d | gpg -dq
	then
		echo 'ERROR: failed to decrypt base64-encoded ciphertext'
		rm "${CIPHERTEXT_TEMP_FILE}" > /dev/null 2>&1
		return 1
	fi
	rm "${CIPHERTEXT_TEMP_FILE}" > /dev/null 2>&1
	return 0
}


### ETCD

etcd_cluster_is_ready() {
	# Usage: etcd_cluster_is_ready

	service_is_healthy etcd_0 \
		&& service_is_healthy etcd_1 \
		&& service_is_healthy etcd_2
}

wait_for_etcd() {
	# Usage: wait_for_etcd

	TIMEOUT_SECS='300'
	WAIT_BETWEEN_CHECKS='20'
	START_TIMESTAMP="$(current_timestamp)"
	TIMEOUT_TIMESTAMP="$(( START_TIMESTAMP + TIMEOUT_SECS ))"

	while ! etcd_cluster_is_ready
	do
		if [ "$(current_timestamp)" -ge "${TIMEOUT_TIMESTAMP}" ]
		then
			echo 'ERROR: timed out while waiting for etcd cluster enter a healthy state'
			echo 'View etcd services: `docker-compose ps etcd_0 etcd_1 etcd_2`'
			echo 'View logs for etcd: `docker-compose logs etcd_0 etcd_1 etcd_2`'
			return 1
		fi
		sleep "${WAIT_BETWEEN_CHECKS}"
	done
}

setup_etcd_auth() {
	# Usage: setup_etcd_auth

	ETCD_INSTANCE='etcd_0'
	ETCDCTL_API=3
	export ETCDCTL_API

	echo 'Setting up auth for etcd cluster'
	docker-compose exec -e ETCDCTL_API "${ETCD_INSTANCE}" etcdctl role add root
	docker-compose exec -e ETCDCTL_API "${ETCD_INSTANCE}" etcdctl user add root --new-user-password=root
	docker-compose exec -e ETCDCTL_API "${ETCD_INSTANCE}" etcdctl user grant-role root root
	docker-compose exec -e ETCDCTL_API "${ETCD_INSTANCE}" etcdctl auth enable
	printf '\n'
}

start_etcd() {
	# Usage: start_etcd

	docker-compose up -d etcd_0 etcd_1 etcd_2
	printf '\n'
	wait_for_etcd && setup_etcd_auth
}


### NGINX

wait_for_nginx() {
	# Usage: wait_for_nginx

	TIMEOUT_SECS='300'
	WAIT_BETWEEN_CHECKS='10'
	START_TIMESTAMP="$(current_timestamp)"
	TIMEOUT_TIMESTAMP="$(( START_TIMESTAMP + TIMEOUT_SECS ))"

	while ! service_is_healthy nginx
	do
		if [ "$(current_timestamp)" -ge "${TIMEOUT_TIMESTAMP}" ]
		then
			echo 'ERROR: timed out while waiting for nginx to enter a healthy state'
			echo 'Check status of nginx: `docker-compose ps nginx`'
			echo 'View logs for nginx: `docker-compose logs nginx`'
			return 1
		fi
		sleep "${WAIT_BETWEEN_CHECKS}"
	done
}

start_nginx() {
	# Usage: start_nginx

	docker-compose up -d nginx
	printf '\n'
	wait_for_nginx
}


### Vault

unseal_key() {
	# Usage: unseal_key <INIT_RESPONSE_FILE>

	INIT_RESPONSE_FILE="${1}"
	B64_UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' < "${INIT_RESPONSE_FILE}" | tr -d '"')"

	gpg_decrypt_base64 "${B64_UNSEAL_KEY}"
}

initial_root_token() {
	# Usage: initial_root_token <INIT_RESPONSE_FILE>

	jq -r '.root_token' < "${1}" | tr -d '"'
}

vault_cluster_status() {
	# Usage: vault_cluster_status <INSTANCE_INDEX/NUMBER> <INIT_RESPONSE_FILE>

	INSTANCE_INDEX="${1}"
	SERVICE="vault_${INSTANCE_INDEX}"
	INIT_RESPONSE_FILE="${2}"
	ROOT_TOKEN="$(initial_root_token "${INIT_RESPONSE_FILE}")"

	docker-compose exec -e "VAULT_TOKEN=${ROOT_TOKEN}" "${SERVICE}" vault operator members || return 1
	printf '\n'
}

init_vault_instance() {
	# Usage: init_vault_instance <INSTANCE_NUMBER/INDEX> <INIT_RESPONSE_FILE> <UNSEAL_GPG_KEY_ID>

	INSTANCE_INDEX="${1}"
	SERVICE="vault_${INSTANCE_INDEX}"
	INIT_RESPONSE_FILE="${2}"
	UNSEAL_GPG_KEY="${3}"
	UNSEAL_GPG_KEY_B64="$(gpg_export_public_key_to_base64 "${UNSEAL_GPG_KEY}")"
	GPG_KEY_PATH_IN_CONTAINER='pub-key.gpg.b64'
	NUM_SHARDS='1'
	SHARD_THRESHOLD='1'

	echo "Initialising '${SERVICE}'"

	docker-compose exec "${SERVICE}" \
		/bin/sh -c "printf '%s' \"${UNSEAL_GPG_KEY_B64}\" > ${GPG_KEY_PATH_IN_CONTAINER}"

	docker-compose exec "${SERVICE}" vault operator init \
		-key-shares="${NUM_SHARDS}" \
		-key-threshold="${SHARD_THRESHOLD}" \
		-pgp-keys="${GPG_KEY_PATH_IN_CONTAINER}" \
		-format=json \
		2> /dev/null \
		> "${INIT_RESPONSE_FILE}"

	echo "Initial root token and GPG-encrypted key shares/shards saved to '${INIT_RESPONSE_FILE}'"
	printf '\n'
}


unseal_vault_instance() {
	# Usage: unseal_vault_instance <INSTANCE_INDEX/NUMBER> <INIT_RESPONSE_FILE>

	INSTANCE_INDEX="${1}"
	SERVICE="vault_${INSTANCE_INDEX}"
	INIT_RESPONSE_FILE="${2}"

	if ! unseal_key "${INIT_RESPONSE_FILE}" > /dev/null 2>&1
	then
		echo 'ERROR: failed to unseal vault because the unseal key could not be obtained'
		return 1
	fi

	echo "Unsealing '${SERVICE}'"
	if ! docker-compose exec "${SERVICE}" vault operator unseal "$(unseal_key "${INIT_RESPONSE_FILE}")"
	then
		echo "ERROR: failed to unseal vault instance '${SERVICE}'"
		return 1
	fi
	printf '\n'
}

start_vault_cluster_leader() {
	# Usage: start_vault_cluster_leader <INSTANCE_INDEX/NUMBER> <INIT_RESPONSE_FILE> <UNSEAL_GPG_KEY_ID>

	INSTANCE_INDEX="${1}"
	SERVICE="vault_${INSTANCE_INDEX}"
	INIT_RESPONSE_FILE="${2}"
	UNSEAL_GPG_KEY="${3}"
	NUM_SHARDS='1'
	SHARD_THRESHOLD='1'

	echo "Starting '${SERVICE}'"
	docker-compose up -d "${SERVICE}"
	sleep 15
	printf '\n'

	if ! (init_vault_instance "${INSTANCE_INDEX}" "${INIT_RESPONSE_FILE}" "${UNSEAL_GPG_KEY}" \
		&& unseal_vault_instance "${INSTANCE_INDEX}" "${INIT_RESPONSE_FILE}")
	then
		echo "ERROR: failed to start vault cluster leader '${SERVICE}'"
		return 1
	fi

	vault_cluster_status "${INSTANCE_INDEX}" "${INIT_RESPONSE_FILE}"
	printf '\n'
}

start_vault_nonleader() {
	# Usage: start_vault_nonleader <INSTANCE_INDEX/NUMBER> <INIT_RESPONSE_FILE>

	INSTANCE_INDEX="${1}"
	SERVICE="vault_${INSTANCE_INDEX}"
	INIT_RESPONSE_FILE="${2}"

	echo "Starting '${SERVICE}'"
	docker-compose up -d "${SERVICE}"
	sleep 15
	printf '\n'

	if ! unseal_vault_instance "${INSTANCE_INDEX}" "${INIT_RESPONSE_FILE}"
	then
		echo "ERROR: failed to start vault instance '${SERVICE}' because it could not be unsealed"
		return 1
	fi

	vault_cluster_status "${INSTANCE_INDEX}" "${INIT_RESPONSE_FILE}"
	printf '\n'
}



# ----- Process -----

check_dependencies \
	&& validate_gpg_key_for_unsealing "${UNSEAL_GPG_KEY_ID}" \
	&& start_etcd \
	&& start_vault_cluster_leader 0 "${INIT_RESPONSE_JSON_PATH}" "${UNSEAL_GPG_KEY_ID}" \
	&& start_vault_nonleader 1 "${INIT_RESPONSE_JSON_PATH}" \
	&& start_vault_nonleader 2 "${INIT_RESPONSE_JSON_PATH}" \
	&& start_nginx \
	|| return 1

VAULT_ADDR='http://127.0.0.1:8200' # port 8200 from nginx is exposed on the host machine
export VAULT_ADDR

VAULT_TOKEN="$(initial_root_token "${INIT_RESPONSE_JSON_PATH}")"
export VAULT_TOKEN
