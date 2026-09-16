# deploy-opnform-proxies-survive-a-release

Let ingress and api-internal survive a deploy by dropping the depends_on that makes Compose recreate them as dependents of api and ui
