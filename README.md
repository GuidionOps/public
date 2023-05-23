# Public Repo

Resources for which we need no read protection.

## Developer Terraform Preparation Script

[Terraform is run on the local developer machines for Development stages](https://guidiondev.atlassian.net/wiki/spaces/DIG/pages/4002414604/Development+Stage+Deploys).

To configure the backend correctly, a helper script is provided. The script takes two arguments; the project name, and the application name. For example, when configuring the development backend for the 'circleci' application in the 'web' project, run:

```sh
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s -- web circleci
```

It will try and be helpful if arguments are not supplied:

```sh
# Without providing project name
#
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s

Please provde the project name as the first argument (e.g. 'web'
Hint:
2023-03-21 13:15:37 aws-cloudtrail-logs-web-dev-events-test
2023-05-08 15:58:42 nuna-dev-afsprk-nl-origin
2023-05-17 10:37:55 web-dev-terraform-backends
```

```sh
# Without providing application name
#
curl -s https://raw.githubusercontent.com/GuidionOps/public/master/prepare_terraform_backend.sh | bash -s -- web

Please provde one of these for the 'workspace' name as the second argument:
                           PRE afsprk_nl/
                           PRE circleci/
```
