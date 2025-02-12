require 'spec_helper'

require 'puppet_x/puppetlabs/tune.rb'

def suppress_standard_output
  allow(STDOUT).to receive(:puts)
end

describe PuppetX::Puppetlabs::Tune do
  # Do not query PuppetDB when unit testing this class.
  subject(:tune) { described_class.new(:local => true) }

  # Allows mergeups in the PE implementation of this class.
  pe_2019_or_newer = Gem::Version.new(Puppet.version) >= Gem::Version.new('6.0.0')

  before(:each) do
    suppress_standard_output
  end

  context 'with its tunable methods' do
    it 'tunes a known set of classes' do
      class_names = [
        'certificate_authority',
        'master',
        'console',
        'puppetdb',
        'database',
        'amq::broker',
        'orchestrator',
        'primary_master',
        'primary_master_replica',
        'enabled_primary_master_replica',
        'compile_master',
      ]
      class_names.delete('amq::broker') if pe_2019_or_newer
      expect(tune::tunable_class_names).to eq(class_names)
    end

    it 'tunes a known set of settings' do
      param_names = [
        'puppet_enterprise::master::puppetserver::jruby_max_active_instances',
        'puppet_enterprise::master::puppetserver::reserved_code_cache',
        'puppet_enterprise::profile::amq::broker::heap_mb',
        'puppet_enterprise::profile::console::java_args',
        'puppet_enterprise::profile::database::shared_buffers',
        'puppet_enterprise::profile::master::java_args',
        'puppet_enterprise::profile::orchestrator::java_args',
        'puppet_enterprise::profile::puppetdb::java_args',
        'puppet_enterprise::puppetdb::command_processing_threads',
      ]
      param_names.delete('puppet_enterprise::profile::amq::broker::heap_mb') if pe_2019_or_newer
      expect(tune::tunable_param_names).to eq(param_names)
    end
  end

  context 'with its supporting methods' do
    it 'can detect an unknown infrastructure' do
      nodes = { 'primary_masters' => [] }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::unknown_infrastructure?).to eq(true)
    end

    it 'can detect a monolithic infrastructure' do
      nodes = {
        'console_hosts'  => [],
        'puppetdb_hosts' => [],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::monolithic?).to eq(true)
    end

    it 'can detect a split infrastructure' do
      nodes = {
        'console_hosts'  => ['console'],
        'puppetdb_hosts' => ['puppetdb'],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::monolithic?).to eq(false)
    end

    it 'can detect ha infrastructure' do
      nodes = { 'replica_masters' => ['replica'] }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_ha?).to eq(true)
    end

    it 'can detect compile masters' do
      nodes = { 'compile_masters' => ['compile'] }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_compile_masters?).to eq(true)
    end

    it 'can detect an external database host' do
      nodes = {
        'primary_masters' => ['master'],
        'database_hosts'  => ['postgresql'],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_external_database?).to eq(true)
    end

    it 'can detect local and external databases' do
      nodes_with_class = {
        'database' => ['master', 'postgresql']
      }
      nodes = {
        'primary_masters' => ['master'],
        'replica_masters' => [],
        'database_hosts'  => ['master', 'postgresql'],
      }
      tune.instance_variable_set(:@nodes_with_class, nodes_with_class)
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_local_and_external_databases?).to eq(true)
    end

    it 'can detect puppetdb on all masters' do
      nodes_with_class = {
        'puppetdb' => ['master', 'replica', 'compile']
      }
      nodes = {
        'primary_masters' => ['master'],
        'replica_masters' => ['replica'],
        'compile_masters' => ['compile'],
      }
      tune.instance_variable_set(:@nodes_with_class, nodes_with_class)
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_puppetdb_on_all_masters?).to eq(true)
    end

    it 'can detect a monolithic master' do
      nodes = {
        'primary_masters' => ['master'],
        'console_hosts'   => [],
        'puppetdb_hosts'  => [],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::monolithic_master?('master')).to eq(true)
    end

    it 'can detect a replica master' do
      nodes = {
        'primary_masters' => ['master'],
        'replica_masters' => ['replica'],
        'console_hosts'   => [],
        'puppetdb_hosts'  => [],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::replica_master?('replica')).to eq(true)
    end

    it 'can detect a compile master' do
      nodes = {
        'compile_masters' => ['compile'],
      }
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::compile_master?('compile')).to eq(true)
    end

    it 'can detect a compiler' do
      nodes_with_class = {
        'puppetdb' => ['master', 'compile1']
      }
      nodes = {
        'primary_masters' => ['master'],
        'replica_masters' => [],
        'console_hosts'   => [],
        'compile_masters' => ['compile1'],
        'puppetdb_hosts'  => ['compile1'],
        'database_hosts'  => [],
      }
      tune.instance_variable_set(:@nodes_with_class, nodes_with_class)
      tune.instance_variable_set(:@nodes_with_role, nodes)

      expect(tune::with_compilers?).to eq(true)
    end

    it 'can detect a class on a host' do
      nodes_with_class = { 'console' => ['console'] }
      tune.instance_variable_set(:@nodes_with_class, nodes_with_class)

      expect(tune::node_with_class?('console', 'console')).to eq(true)
    end

    it 'can detect classes on a host' do
      nodes_with_class = {
        'certificate_authority'          => [],
        'master'                         => [],
        'console'                        => ['console'],
        'puppetdb'                       => [],
        'database'                       => [],
        'amq::broker'                    => [],
        'orchestrator'                   => [],
        'primary_master'                 => [],
        'primary_master_replica'         => [],
        'enabled_primary_master_replica' => [],
        'compile_master'                 => [],
      }
      classes_for_node = {
        'certificate_authority'          => false,
        'master'                         => false,
        'console'                        => true,
        'puppetdb'                       => false,
        'database'                       => false,
        'amq::broker'                    => false,
        'orchestrator'                   => false,
        'primary_master'                 => false,
        'primary_master_replica'         => false,
        'enabled_primary_master_replica' => false,
        'compile_master'                 => false,
      }
      nodes_with_class.delete('amq::broker') if pe_2019_or_newer
      classes_for_node.delete('amq::broker') if pe_2019_or_newer
      tune.instance_variable_set(:@nodes_with_class, nodes_with_class)

      expect(tune::tunable_classes_for_node('console')).to eq(classes_for_node)
    end

    # it 'can detect that JRuby9K is enabled for the puppetsever service' do
    # end

    it 'can extract common settings' do
      tune.instance_variable_set(:@options, :common => true)
      tune.instance_variable_set(:@collected_settings_common, {})
      collected_nodes = {
        'node_1' => {
          'settings' => {
            'params' => {
              'a' => 1,
              'b' => 'b'
            }
          }
        },
        'node_2' => {
          'settings' => {
            'params' => {
              'a' => 2,
              'b' => 'b'
            }
          }
        }
      }
      collected_nodes_without_common_settings = {
        'node_1' => { 'settings' => { 'params' => { 'a' => 1 } } },
        'node_2' => { 'settings' => { 'params' => { 'a' => 2 } } }
      }
      collected_settings_common = { 'b' => 'b' }

      tune.instance_variable_set(:@collected_nodes, collected_nodes)
      tune::collect_optimized_settings_common_to_all_nodes

      expect(tune.instance_variable_get(:@collected_settings_common)).to eq(collected_settings_common)
      expect(tune.instance_variable_get(:@collected_nodes)).to eq(collected_nodes_without_common_settings)
    end

    it 'can enforce minimum system requirements' do
      tune.instance_variable_set(:@options, :force => false)

      resources = { 'cpu' => 1, 'ram' => 4096 }
      expect(tune::meets_minimum_system_requirements?(resources)).to eq(false)

      resources = { 'cpu' => 2, 'ram' => 5120 }
      expect(tune::meets_minimum_system_requirements?(resources)).to eq(false)

      resources = { 'cpu' => 2, 'ram' => 5806 }
      expect(tune::meets_minimum_system_requirements?(resources)).to eq(true)

      resources = { 'cpu' => 2, 'ram' => 6144 }
      expect(tune::meets_minimum_system_requirements?(resources)).to eq(true)
    end

    it 'can disable minimum system requirements' do
      tune.instance_variable_set(:@options, :force => true)
      resources = { 'cpu' => 1, 'ram' => 4096 }

      expect(tune::meets_minimum_system_requirements?(resources)).to eq(true)
    end

    it 'can convert a string to bytes with a g unit' do
      bytes_string = '16g'
      bytes = 17179869184
      expect(tune::string_to_bytes(bytes_string)).to eq(bytes)
    end

    it 'can convert a string to bytes with a m unit' do
      bytes_string = '16384m'
      bytes = 17179869184
      expect(tune::string_to_bytes(bytes_string)).to eq(bytes)
    end

    it 'can convert a string to bytes with a k unit' do
      bytes_string = '16777216k'
      bytes = 17179869184
      expect(tune::string_to_bytes(bytes_string)).to eq(bytes)
    end

    it 'can convert a string to bytes with a b unit' do
      bytes_string = '17179869184b'
      bytes = 17179869184
      expect(tune::string_to_bytes(bytes_string)).to eq(bytes)
    end

    it 'can convert a string to bytes without a unit' do
      bytes_string = '16'
      bytes = 17179869184
      expect(tune::string_to_bytes(bytes_string)).to eq(bytes)
    end

    it 'can convert a string to megabytes with a g unit' do
      bytes_string = '1g'
      megabytes = 1024
      expect(tune::string_to_megabytes(bytes_string)).to eq(megabytes)
    end

    it 'can convert a string to megabytes with a m unit' do
      bytes_string = '1024m'
      megabytes = 1024
      expect(tune::string_to_megabytes(bytes_string)).to eq(megabytes)
    end

    it 'can convert a string to megabytes without a unit' do
      bytes_string = '1024'
      megabytes = 1024
      expect(tune::string_to_megabytes(bytes_string)).to eq(megabytes)
    end
  end
end
