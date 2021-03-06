
# Image URL to use all building/pushing image targets
IMG ?= gcr.io/flink-operator/flink-operator:latest
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"
# The Kubernetes namespace in which the operator will be deployed.
FLINK_OPERATOR_NAMESPACE ?= flink-operator-system

#################### Local build and test ####################

# Build the flink-operator binary
build: generate fmt vet
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on go build -a -o bin/flink-operator main.go
	go mod tidy

# Run tests.
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out
	go mod tidy
	echo $(FLINK_OPERATOR_NAMESPACE)

# Run tests in the builder container.
test-in-docker: builder-image
	docker run flink-operator-builder make test

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./main.go
	go mod tidy

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./api/v1beta1/..." output:crd:artifacts:config=config/crd/bases
	go mod tidy

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile=./hack/boilerplate.go.txt paths=./api/v1beta1/...

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.2.0-beta.2
CONTROLLER_GEN=$(shell go env GOPATH)/bin/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif


#################### Docker image ####################

# Builder image which builds the flink-operator binary from the source code.
builder-image:
	docker build -t flink-operator-builder -f Dockerfile.builder .

# Build the Flink Operator docker image
operator-image: builder-image test-in-docker
	docker build  -t ${IMG} --label git-commit=$(shell git rev-parse HEAD) .
	@echo "updating kustomize image patch file for Flink Operator resource"
	sed -e 's#image: .*#image: '"${IMG}"'#' ./config/default/manager_image_patch.template >./config/default/manager_image_patch.yaml

# Push the Flink Operator docker image to container registry.
push-operator-image:
	docker push ${IMG}


#################### Deployment ####################

# Install CRDs into a cluster
install: manifests
	kubectl apply -f config/crd/bases

# Deploy cert-manager which is required by webhooks of the operator.
webhook-cert:
	bash scripts/generate_cert.sh --service flink-operator-webhook-service --secret webhook-server-cert -n $(FLINK_OPERATOR_NAMESPACE)

config/default/manager_image_patch.yaml:
	cp config/default/manager_image_patch.template config/default/manager_image_patch.yaml

# Deploy the operator in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests webhook-cert config/default/manager_image_patch.yaml
	kubectl apply -f config/crd/bases
	$(eval CA_BUNDLE := $(shell kubectl get secrets/webhook-server-cert -n $(FLINK_OPERATOR_NAMESPACE) -o jsonpath="{.data.tls\.crt}"))
	kubectl kustomize config/default \
			| sed -e "s/flink-operator-system/$(FLINK_OPERATOR_NAMESPACE)/g" \
			| sed -e "s/Cg==/$(CA_BUNDLE)/g" \
			| kubectl apply -f -

undeploy:
	kubectl kustomize config/default \
			| sed -e "s/flink-operator-system/$(FLINK_OPERATOR_NAMESPACE)/g" \
			| kubectl delete -f - \
			|| true
	kubectl delete -f config/crd/bases || true

# Deploy the sample Flink clusters in the Kubernetes cluster
samples:
	kubectl apply -f config/samples/
