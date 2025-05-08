init:
	terraform init

plan:
	terraform plan -out=plan.tfplan

apply:
	terraform apply plan.tfplan

show:
	terraform show -json plan.tfplan > plan.json
