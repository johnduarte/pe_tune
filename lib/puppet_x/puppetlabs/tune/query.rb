require 'puppet/util/pe_conf'
require 'puppet/util/pe_conf/recover'

module PuppetX
  module Puppetlabs
    # Tune optimized settings.
    class Tune
      # Interface to Puppet::Util::Puppetdb, Puppet::Util::Pe_conf, and Puppet::Util::Pe_conf::Recover
      class Query
        attr_reader :environment
        attr_reader :environmentpath

        def initialize
          @environment = 'production'
          @environmentpath = '/etc/puppetlabs/code/environments'
        end

        # PE-15116 overrides 'environment' and 'environmentpath' in the 'puppet infrastructure' face.
        # The original values are required by methods in this class.

        def pe_environment(certname)
          begin
            environment = catalog_environment(certname)
          rescue Puppet::Error
            environment = []
          end
          if environment.empty?
            Puppet.debug("No Environment found in PuppetDB using: #{certname}")
            Puppet.debug("Querying 'puppet config print environment' for Environment")
            @environment = Puppet::Util::Execution.execute('/opt/puppetlabs/puppet/bin/puppet config print environment --section master').chomp
          else
            @environment = environment[0]
          end
          @environmentpath = Puppet::Util::Execution.execute('/opt/puppetlabs/puppet/bin/puppet config print environmentpath --section master').chomp
        end

        # Query PuppetDB for the environment of a node.

        def catalog_environment(certname)
          Puppet.debug("Querying PuppetDB for Environment using: #{certname}")
          pql = ['from', 'nodes',
                ['extract', ['certname', 'catalog_environment'],
                  ['and',
                    ['=', 'certname', certname],
                  ]
                ]
              ]
          results = query_puppetdb(pql)
          Puppet.debug(results)
          results.map { |resource| resource.fetch('catalog_environment') }
        end

        # Query PuppetDB for the count of active nodes.

        def active_node_count
          Puppet.debug('Querying PuppetDB for Active Nodes')
          pql = ['from', 'nodes',
                ['and',
                  ['=', ['node', 'active'], true],
                ]
              ]
          results = query_puppetdb(pql)
          Puppet.debug(results)
          results.count
        end

        # Query PuppetDB for config_retrieval or total time metrics.

        # "name" => "catalog_application",
        # "name" => "config_retrieval",
        # "name" => "convert_catalog",
        # "name" => "fact_generation",
        # "name" => "node_retrieval",
        # "name" => "plugin_sync",
        # "name" => "transaction_evaluation",
        # "name" => "total",

        def average_compile_time(query_limit = 1000)
          Puppet.debug('Querying PuppetDB for Average Compile Time')
          pql = ['from', 'reports',
                ['extract',
                  ['hash', 'start_time', 'end_time', 'metrics'],
                ],
                ['limit', query_limit]
              ]
          results = query_puppetdb(pql)
          random_report_hash = results.sample['hash']
          Puppet.debug("Random report: #{random_report_hash}")
          # run_times = results.map do |report|
          #   Time.parse(report['end_time']) - Time.parse(report['start_time'])
          # end
          # avg_run_time = (run_times.inject(0.0) { |sum, element| sum + element } / run_times.size).ceil
          # Filter out reports that do not contain metric data.
          results.delete_if { |report| report['metrics']['data'].empty? }
          # Collect config_retrieval time, or if absent (for a run with a catalog compilation error), total time.
          config_retrieval_times = results.map do |report|
            report['metrics']['data'].select { |md|
              md['category'] == 'time' && (md['name'] == 'config_retrieval' || md['name'] == 'total')
            }.first.fetch('value')
          end
          avg_config_retrieval_time = config_retrieval_times.reduce(0.0) { |sum, element| sum + element } / config_retrieval_times.size
          avg_config_retrieval_time.ceil
        end

        # Query PuppetDB for nodes with a class.

        def infra_nodes_with_class(classname)
          Puppet.debug("Querying PuppetDB for Class: Puppet_enterprise::Profile::#{classname}")
          pql = ['from', 'resources',
                ['extract', ['certname', 'parameters'],
                  ['and',
                    ['=', 'type', 'Class'],
                    ['=', 'environment', @environment],
                    ['=', 'title', "Puppet_enterprise::Profile::#{classname}"],
                    ['=', ['node', 'active'], true],
                  ]
                ]
              ]
          results = query_puppetdb(pql)
          Puppet.debug(results)
          results.map { |resource| resource.fetch('certname') }
        end

        # Query PuppetDB for facts for a node.

        def node_facts(certname)
          node_facts = {}
          if recover_with_instance_method?
            recover = Puppet::Util::Pe_conf::Recover.new
            node_facts = recover.facts_for_node(certname, @environment)
          else
            facts_hash = Puppet::Util::Pe_conf::Recover.facts_for_node(certname, @environment)
            if facts_hash.key?('puppetversion')
              node_facts = facts_hash
            else
              # Prior to PE-22444, facts are returned as a Hash with elements in this format: {"name"=>"puppetversion", "value"=>"4.10.10"} => nil
              facts_hash.each do |fact, _nil|
                node_facts[fact['name']] = fact['value']
              end
            end
          end
          node_facts
        end

        # Return settings configured in Hiera and the Classifier, identifying duplicates and merging the results.

        def hiera_classifier_settings(certname, settings)
          duplicates = []
          overrides_hiera, overrides_classifier = hiera_classifier_overrides(certname, settings)
          overrides = overrides_hiera
          overrides_classifier.each do |classifier_k, classifier_v|
            next unless settings.include?(classifier_k)
            if overrides.key?(classifier_k)
              Puppet.debug("# Duplicate settings for #{certname}: #{classifier_k} Classifier: #{classifier_v} Hiera: #{overrides_hiera[classifier_k]}")
              duplicates.push(classifier_k)
            end
            # Classifer settings take precedence over Hiera settings.
            # Hiera settings include pe.conf.
            overrides[classifier_k] = classifier_v
          end
          { 'params' => overrides, 'duplicates' => duplicates }
        end

        # Internal helper methods.

        private

        # If puppetdb would be required at the top of the file,
        # then it would be autoloaded/required as part of the install process,
        # before the puppetdb package was installed, producing an error.

        def query_puppetdb(pql)
          require 'puppet/util/puppetdb'
          Puppet::Util::Puppetdb.query_puppetdb(pql)
        end

        # Extract the beating heart of a puppet compiler for lookup purposes.

        def hiera_classifier_overrides(certname, settings)
          if recover_with_instance_method?
            recover = Puppet::Util::Pe_conf::Recover.new
            node_facts = recover.facts_for_node(certname, @environment)
            node_terminus = recover.get_node_terminus
            overrides_hiera = recover.find_hiera_overrides(certname, settings, node_facts, @environment, node_terminus)
            overrides_classifier = recover.classifier_overrides_for_node(certname, node_facts, node_facts['::trusted'])
          else
            node_facts = Puppet::Util::Pe_conf::Recover.facts_for_node(certname, @environment)
            if recover_with_node_terminus_method?
              node_terminus = Puppet::Util::Pe_conf::Recover.get_node_terminus
              overrides_hiera = Puppet::Util::Pe_conf::Recover.find_hiera_overrides(certname, settings, node_facts, @environment, node_terminus)
            else
              overrides_hiera = Puppet::Util::Pe_conf::Recover.find_hiera_overrides(settings, node_facts, @environment)
            end
            overrides_classifier = Puppet::Util::Pe_conf::Recover.classifier_overrides_for_node(certname, node_facts, node_facts['::trusted'])
          end
          [overrides_hiera, overrides_classifier]
        end

        # PE-24106 changes Recover to a class with instance methods.

        def recover_with_instance_method?
          defined?(Puppet::Util::Pe_conf::Recover.facts_for_node) != 'method'
        end

        # In some versions, Puppet::Util::Pe_conf::Recover does not implement get_node_terminus() and implements find_hiera_overrides(params, facts, environment)

        def recover_with_node_terminus_method?
          defined?(Puppet::Util::Pe_conf::Recover.get_node_terminus) == 'method'
        end
      end
    end
  end
end
