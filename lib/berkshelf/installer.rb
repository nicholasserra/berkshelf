require 'berkshelf/api-client'

module Berkshelf
  class Installer
    attr_reader :berksfile
    attr_reader :lockfile
    attr_reader :downloader

    # @param [Berkshelf::Berksfile] berksfile
    def initialize(berksfile)
      @berksfile  = berksfile
      @lockfile   = berksfile.lockfile
      @downloader = Downloader.new(berksfile)
    end

    def build_universe
      berksfile.sources.collect do |source|
        Thread.new do
          begin
            Berkshelf.formatter.msg("Fetching cookbook index from #{source.uri}...")
            source.build_universe
          rescue Berkshelf::APIClientError => ex
            Berkshelf.formatter.warn "Error retrieving universe from source: #{source}"
            Berkshelf.formatter.warn "  * [#{ex.class}] #{ex}"
          end
        end
      end.map(&:join)
    end

    # @return [Array<Berkshelf::CachedCookbook>]
    def run
      reduce_lockfile!

      dependencies, cookbooks = if lockfile.trusted?
        install_from_lockfile
      else
        install_from_universe
      end

      to_lock = dependencies.select do |dependency|
        berksfile_dependencies.include?(dependency.name)
      end

      lockfile.graph.update(cookbooks)
      lockfile.update(to_lock)
      lockfile.save

      cookbooks
    end

    # Install all the dependencies from the lockfile graph.
    #
    # @return [Array<CachedCookbook>]
    #   the list of installed cookbooks
    def install_from_lockfile
      dependencies = lockfile.graph.locks.values

      # Only construct the universe if we are going to download things
      unless dependencies.all?(&:downloaded?)
        build_universe
      end

      cookbooks = dependencies.sort.collect do |dependency|
        install(dependency)
      end

      [dependencies, cookbooks]
    end

    # Resolve and install the dependencies from the "universe", updating the
    # lockfile appropiately.
    #
    # @return [Array<CachedCookbook>]
    #   the list of installed cookbooks
    def install_from_universe
      dependencies = lockfile.graph.locks.values + berksfile.dependencies
      dependencies = dependencies.inject({}) do |hash, dependency|
        # Fancy way of ensuring no duplicate dependencies are used...
        hash[dependency.name] ||= dependency
        hash
      end.values

      resolver = Resolver.new(berksfile, dependencies)

      # Download all SCM locations first, since they might have additional
      # constraints that we don't yet know about
      dependencies.select(&:scm_location?).each do |dependency|
        Berkshelf.formatter.fetch(dependency)
        dependency.download
      end

      # Unlike when installing from the lockfile, we _always_ need to build
      # the universe when installing from the universe... duh
      build_universe

      # Add any explicit dependencies for already-downloaded cookbooks (like
      # path locations)
      dependencies.each do |dependency|
        if cookbook = dependency.cached_cookbook
          resolver.add_explicit_dependencies(cookbook)
        end
      end

      cookbooks = resolver.resolve.sort.collect do |dependency|
        install(dependency)
      end

      [dependencies, cookbooks]
    end

    # Install a specific dependency.
    #
    # @param [Dependency]
    #   the dependency to install
    # @return [CachedCookbook]
    #   the installed cookbook
    def install(dependency)
      if dependency.downloaded?
        Berkshelf.formatter.use(dependency)
        dependency.cached_cookbook
      else
        name, version = dependency.name, dependency.locked_version.to_s
        source   = berksfile.source_for(name, version)
        cookbook = source.cookbook(name, version)

        Berkshelf.formatter.install(source, cookbook)

        stash = downloader.download(name, version)
        CookbookStore.import(name, version, stash)
      end
    end

    private

    # Iterate over each top-level dependency defined in the lockfile and
    # check if that dependency is still defined in the Berksfile.
    #
    # If the dependency is no longer present in the Berksfile, it is "safely"
    # removed using {Lockfile#unlock} and {Lockfile#remove}. This prevents
    # the lockfile from "leaking" dependencies when they have been removed
    # from the Berksfile, but still remained locked in the lockfile.
    #
    # If the dependency exists, a constraint comparison is conducted to verify
    # that the locked dependency still satisifes the original constraint. This
    # handles the edge case where a user has updated or removed a constraint
    # on a dependency that already existed in the lockfile.
    #
    # @raise [OutdatedDependency]
    #   if the constraint exists, but is no longer satisifed by the existing
    #   locked version
    #
    # @return [Array<Dependency>]
    def reduce_lockfile!
      lockfile.dependencies.each do |dependency|
        if berksfile_dependencies.include?(dependency.name)
          locked = lockfile.graph.find(dependency)
          next if locked.nil?

          unless dependency.version_constraint.satisfies?(locked.version)
            raise OutdatedDependency.new(locked, dependency)
          end
        else
          lockfile.unlock(dependency)
        end
      end
    end

    def berksfile_dependencies
      @berksfile_dependencies ||= berksfile.dependencies.map(&:name)
    end
  end
end
