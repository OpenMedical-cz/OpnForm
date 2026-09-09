#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

def assert(condition, message)
  return if condition

  warn message
  exit 1
end

source_workflow = YAML.load_file('.github/workflows/ci-cd.yml')
release_workflow = YAML.load_file('.github/workflows/venova-staging.yml')

bootstrap = source_workflow.fetch('jobs')['venova-ghcr-bootstrap']
assert(!bootstrap.nil?, 'CI must define the internal GHCR bootstrap job.')
bootstrap_condition = bootstrap.fetch('if')

assert(bootstrap.fetch('uses') == './.github/workflows/venova-staging.yml',
       'GHCR bootstrap must call the dedicated release workflow.')
assert(bootstrap.fetch('with').fetch('publish_on_internal_pull_request') == true,
       'GHCR bootstrap must explicitly opt in to internal pull request image publication.')
assert(bootstrap_condition.include?("github.event_name == 'pull_request'"),
       'GHCR bootstrap must run only for pull requests.')
assert(bootstrap_condition.include?('github.event.pull_request.head.repo.full_name == github.repository'),
       'GHCR bootstrap must reject pull requests from forks.')

release_input = release_workflow.fetch(true).fetch('workflow_call').fetch('inputs').fetch('publish_on_internal_pull_request')
images_condition = release_workflow.fetch('jobs').fetch('images').fetch('if')
manifest_steps = release_workflow.fetch('jobs').fetch('images').fetch('steps').select do |step|
  step['name']&.include?('immutable staging release manifest')
end
dispatch_condition = release_workflow.fetch('jobs').fetch('dispatch-private-staging').fetch('if')

assert(release_input.fetch('type') == 'boolean' && release_input.fetch('default') == false,
       'Release workflow must default bootstrap image publication to disabled.')
assert(images_condition.include?('inputs.publish_on_internal_pull_request') &&
       images_condition.include?("github.event_name == 'pull_request'"),
       'Image publication must require the explicit bootstrap input on pull requests.')
assert(manifest_steps.length == 2 && manifest_steps.all? { |step| step.fetch('if').include?("github.event_name == 'push'") },
       'GHCR bootstrap must not produce a deployable release manifest.')
assert(dispatch_condition.include?("github.event_name == 'push'") &&
       dispatch_condition.include?("github.ref == 'refs/heads/main'"),
       'Private staging dispatch must remain limited to a main push.')
