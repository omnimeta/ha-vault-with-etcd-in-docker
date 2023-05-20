# Local HA Vault Cluster with an ETCD Backend in Docker

Purpose:

* Demonstrate how Vault can integrate with Etcd and a load balancer to provide a highly available Vault cluster.
* Encapsulate the components and procedure required to setup a (virtual) highly available Vault cluster.
* Provide a local environment for practicing interacting with a highly available Vault cluster (and Etcd cluster) and for testing Vault's features.

Output:

* Three Etcd instances which together form a highly available Etcd cluster.
* Three initialised and unsealed Vault instances, each using the Etcd cluster as a storage backend, forming a highly available Vault cluster.
* An Nginx load balancer which distributes requests to the three instances of the Vault cluster.
* A single, GPG-encrypted, unseal key that can be used to unseal any Vault instances (if you choose to manually seal them).
* A Vault root token that you can use to authenticate with the Vault CLI and the Vault UI.

## Requirements

The `start.sh` script is written in portable POSIX shell, uses standard UNIX utilities, and should be compatible with most modern shell environments *as long as the following programs are installed* and accessible via the PATH:

* docker and docker-compose
* jq
* gpg

## Usage

Clone and enter the repository:

``` sh
git clone https://github.com/omnimeta/ha-vault-with-etcd-in-docker.git
```

Ensure your Docker engine runtime is running. On MacOS, make sure Docker Desktop is running. On Linux with systemd, run `systemtl start docker.service`.

Choose a GPG public key to use for encrypting the Vault's unseal key. If you already have a key in mind then make sure you can see the key when running `gpg --list-keys`.
If you cannot see your key then import it using `gpg --import <path-to-key>`, or create a new key pair using `gpg --full-generate-key`.

Export the key's ID (e.g., the email or fingerprint) as the environment variable `UNSEAL_GPG_KEY_ID`. For example:

``` sh
export UNSEAL_GPG_KEY_ID='john.doe@domain'
```

To start the Vault cluster, execute `start.sh` **in the current shell environment**, i.e., without executing it in a sub-shell. You can do this using the dot (`.`) command:

``` sh
. ./start.sh
```

On many modern shells, including bash and zsh, you can also use the `source` command:

``` sh
source start.sh
```

* This will spin up three Etcd instances as part of a highly available Etcd cluster, and then will start, initialise, and unseal three Vault instances, using the Etcd cluster as a storage backend, to form a highly available Vault cluster.

The following environment variables will be set in your current shell:

* `VAULT_ADDR` - the address of a local Nginx load balancer which distributes requests to your Vault instances.
* `VAULT_TOKEN` - the initial root token for your Vault cluster that will automatically be used for authentication by any Vault CLI commands which you may run.

You can access the Vault UI by opening the value of `VAULT_ADDR` in your web browser and using the value of `VAULT_TOKEN` to authenticate.
By default, the value of `VAULT_ADDR` will be http://localhost:8200.

To tear down all containers:

``` sh
docker-compose down --remove-orphans
```
