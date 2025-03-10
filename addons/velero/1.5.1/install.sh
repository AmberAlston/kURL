
function velero_pre_init() {
    if [ -z "$VELERO_NAMESPACE" ]; then
        VELERO_NAMESPACE=velero
    fi
    if [ -z "$VELERO_LOCAL_BUCKET" ]; then
        VELERO_LOCAL_BUCKET=velero
    fi
}

function velero() {
    local src="$DIR/addons/velero/1.5.1"
    local dst="$DIR/kustomize/velero"

    cp -r "$src/crd" "$dst/"
    kubectl apply -k "$dst/crd"

    cp "$src/deployment.yaml" \
        "$src/rbac.yaml" \
        "$dst/"

    render_yaml_file "$src/tmpl-kustomization.yaml" > "$dst/kustomization.yaml"
    render_yaml_file "$src/tmpl-namespace.yaml" > "$dst/namespace.yaml"

    velero_patch_http_proxy "$src" "$dst"

    kubectl create namespace "$VELERO_NAMESPACE" 2>/dev/null || true

    if [ "${K8S_DISTRO}" = "rke2" ]; then
        VELERO_RESTIC_REQUIRES_PRIVILEGED=1
    fi

    if [ "$VELERO_DISABLE_RESTIC" != "1" ]; then
        cp "$src/restic-daemonset.yaml" "$dst/"
        insert_resources "$dst/kustomization.yaml" restic-daemonset.yaml

        if [ "${VELERO_RESTIC_REQUIRES_PRIVILEGED}" = "1" ]; then
            cp "$src/restic-daemonset-privileged.yaml" "$dst/"
            insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-privileged.yaml
        fi
    fi

    velero_kotsadm_local_backend

    kubectl apply -k "$dst"

    velero_binary

    kubectl label -n default --overwrite service/kubernetes velero.io/exclude-from-backup=true
}

function velero_join() {
    velero_binary
}

function velero_binary() {
    local src="$DIR/addons/velero/1.5.1"

    if [ "$VELERO_DISABLE_CLI" = "1" ]; then
        return 0
    fi
    if ! kubernetes_is_master; then
        return 0
    fi

    if [ ! -f "$src/assets/velero.tar.gz" ] && [ "$AIRGAP" != "1" ]; then
        mkdir -p "$src/assets"
        curl -L "https://github.com/vmware-tanzu/velero/releases/download/v1.5.1/velero-v1.5.1-linux-amd64.tar.gz" > "$src/assets/velero.tar.gz"
    fi

    pushd "$src/assets"
    tar xf "velero.tar.gz"
    mv velero-v1.5.1-linux-amd64/velero /usr/local/bin/velero
    popd
}

function velero_kotsadm_local_backend() {
    local src="$DIR/addons/velero/1.5.1"
    local dst="$DIR/kustomize/velero"

    if kubernetes_resource_exists "$VELERO_NAMESPACE" backupstoragelocation default \
        || kubernetes_resource_exists "$VELERO_NAMESPACE" secret aws-credentials; then
        echo "A backend storage location already exists. Skipping creation of new local backend for Velero"
        return 0
    fi

    if [ -z "$OBJECT_STORE_ACCESS_KEY" ] || [ -z "$OBJECT_STORE_SECRET_KEY" ] || [ -z "$OBJECT_STORE_CLUSTER_IP" ]; then
        echo "Local object store not configured. Skipping creation of new local backend for Velero"
        return 0
    fi

    try_1m object_store_create_bucket "$VELERO_LOCAL_BUCKET"

    render_yaml_file "$src/tmpl-kotsadm-local-backend.yaml" > "$dst/kotsadm-local-backend.yaml"
    insert_resources "$dst/kustomization.yaml" kotsadm-local-backend.yaml
}

function velero_patch_http_proxy() {
    local src="$1"
    local dst="$2"

    if [ -n "$PROXY_ADDRESS" ]; then
        render_yaml_file "$src/tmpl-velero-deployment-proxy.yaml" > "$dst/velero-deployment-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" velero-deployment-proxy.yaml
    fi

    if [ -n "$PROXY_ADDRESS" ] && [ "$VELERO_DISABLE_RESTIC" != "1" ]; then
        render_yaml_file "$src/tmpl-restic-daemonset-proxy.yaml" > "$dst/restic-daemonset-proxy.yaml"
        insert_patches_strategic_merge "$dst/kustomization.yaml" restic-daemonset-proxy.yaml
    fi
}
