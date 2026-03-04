# Both projects point at the same monorepo — they diverge only by branch.
# The val project runs on var.val_branch; prod runs on var.prod_branch.

resource "dbtcloud_repository" "val" {
  project_id             = dbtcloud_project.val.id
  remote_url             = var.github_repo_url
  github_installation_id = var.github_installation_id
  git_clone_strategy     = "github_app"

  depends_on = [dbtcloud_project.val]
}

resource "dbtcloud_repository" "prod" {
  project_id             = dbtcloud_project.prod.id
  remote_url             = var.github_repo_url
  github_installation_id = var.github_installation_id
  git_clone_strategy     = "github_app"

  depends_on = [dbtcloud_project.prod]
}
