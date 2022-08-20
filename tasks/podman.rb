#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'puppet_litmus'
require_relative '../lib/task_helper'

# TODO: detect what shell to use
@shell_command = 'bash -lc'

def provision(image, inventory_location, vars)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, '/spec/fixtures/litmus_inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)
  unless vars.nil?
    var_hash = YAML.safe_load(vars)
    run_opts = var_hash['run_opts'].flatten.join(' ') unless var_hash['run_opts'].nil?
  end

  creation_command = "podman run -d -it #{run_opts} #{image}"
  container_id = run_local_command(creation_command).strip[0..11]
  fix_missing_tty_error_message(container_id) unless platform_is_windows?(image)
  node = { 'uri' => container_id,
           'config' => { 'transport' => 'podman', 'podman' => { 'shell-command' => @shell_command } },
           'facts' => { 'provisioner' => 'podman', 'container_id' => container_id, 'platform' => image } }
  unless vars.nil?
    var_hash = YAML.safe_load(vars)
    node['vars'] = var_hash
  end
  group_name = 'podman_nodes'
  add_node_to_group(inventory_hash, node, group_name)
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', node_name: container_id, node: node }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, '/spec/fixtures/litmus_inventory.yaml')
  raise "Unable to find '#{inventory_full_path}'" unless File.file?(inventory_full_path)
  inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
  node_facts = facts_from_node(inventory_hash, node_name)
  remove_command = "podman rm -f #{node_facts['container_id']}"
  run_local_command(remove_command)
  remove_node(inventory_hash, node_name)
  puts "Removed #{node_name}"
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok' }
end

params = JSON.parse(STDIN.read)
action = params['action']
inventory_location = sanitise_inventory_location(params['inventory'])
node_name = params['node_name']
platform = params['platform']
vars = params['vars']
raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?
raise 'specify a platform when provisioning' if action == 'provision' && platform.nil?
unless node_name.nil? ^ platform.nil?
  case action
  when 'tear_down'
    raise 'specify only a node_name, not platform, when tearing down'
  when 'provision'
    raise 'specify only a platform, not node_name, when provisioning'
  else
    raise 'specify only one of: node_name, platform'
  end
end

begin
  result = provision(platform, inventory_location, vars) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue => e
  puts({ _error: { kind: 'provision/podman_failure', msg: e.message } }.to_json)
  exit 1
end
