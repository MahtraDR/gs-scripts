# Spec for the generic autostart loop in scripts/autostart.lic (lines 197-227).
#
# We do NOT load the .lic file because it depends on heavy Lich infrastructure
# (Settings, CharSettings, Script, XMLData, Gem::Version, LICH_VERSION, etc.).
# Instead we extract and exercise the relevant code path through a helper method
# that mirrors the production logic, including the Script.running? guard added
# to prevent double-starts.

# -- Mocks ----------------------------------------------------------------

module MockScript
  @running = {}
  @started = []
  @exists  = Hash.new(true)

  class << self
    attr_reader :started

    def running?(name)
      @running.fetch(name, false)
    end

    def start(name, args: [])
      @started << { name: name, args: args }
    end

    def exists?(name)
      @exists.fetch(name, true)
    end

    def set_running(name, val = true)
      @running[name] = val
    end

    def reset!
      @running = {}
      @started = []
      @exists  = Hash.new(true)
    end
  end
end

module MockSettings
  @store = {}

  class << self
    def []=(key, val)
      @store[key] = val
    end

    def [](key)
      @store[key]
    end

    def reset!
      @store = {}
    end
  end
end

module MockCharSettings
  @store = {}

  class << self
    def []=(key, val)
      @store[key] = val
    end

    def [](key)
      @store[key]
    end

    def reset!
      @store = {}
    end
  end
end

module MockXMLData
  class << self
    attr_accessor :game
  end
end

# -- Helper that mirrors the generic autostart loop -----------------------

# This replicates lines 197-227 of autostart.lic (after the fix).
# It uses the Mock* modules so we can assert behavior without Lich runtime.
def run_generic_autostart_loop(settings_mod: MockSettings,
                               char_settings_mod: MockCharSettings,
                               script_mod: MockScript,
                               xml_data_mod: MockXMLData,
                               lich_version: "5.7.0",
                               respond_output: [])
  for script_list in [settings_mod['scripts'], char_settings_mod['scripts']]
    if script_list.is_a?(Array)
      for script_info in script_list
        if ['infomon', 'repository', 'dependency'].include?(script_info[:name])
          # dependency removal for DR
          if script_info[:name] == 'dependency' && xml_data_mod.game =~ /^DR/
            respond_output << "dependency removed"
            temp_script_list = settings_mod['scripts']
            if temp_script_list.is_a?(Array) &&
               (temp_script_info = temp_script_list.find { |s| s[:name] == script_info[:name] })
              temp_script_list.delete(temp_script_info)
              settings_mod['scripts'] = temp_script_list
            end
            temp_script_list = char_settings_mod['scripts']
            if temp_script_list.is_a?(Array) &&
               (temp_script_info = temp_script_list.find { |s| s[:name] == script_info[:name] })
              temp_script_list.delete(temp_script_info)
              char_settings_mod['scripts'] = temp_script_list
            end
          end
          next
        elsif script_info[:name] == 'lich5-update' &&
              Gem::Version.new(lich_version) > Gem::Version.new('5.6.2')
          next
        else
          next if script_mod.running?(script_info[:name])

          script_mod.start(script_info[:name], args: script_info[:args])
        end
      end
    end
  end
end

# -- Specs ----------------------------------------------------------------

RSpec.describe "Generic autostart loop" do
  before(:each) do
    MockScript.reset!
    MockSettings.reset!
    MockCharSettings.reset!
    MockXMLData.game = "GSIV"
  end

  describe "happy path" do
    it "starts a script that is not already running" do
      MockSettings['scripts'] = [{ name: 'myscript', args: [] }]

      run_generic_autostart_loop
      expect(MockScript.started).to eq([{ name: 'myscript', args: [] }])
    end

    it "starts scripts from both Settings and CharSettings" do
      MockSettings['scripts'] = [{ name: 'script_a', args: [] }]
      MockCharSettings['scripts'] = [{ name: 'script_b', args: ['--verbose'] }]

      run_generic_autostart_loop
      expect(MockScript.started).to contain_exactly(
        { name: 'script_a', args: [] },
        { name: 'script_b', args: ['--verbose'] }
      )
    end
  end

  describe "already running guard (the bug fix)" do
    it "does NOT start a script that is already running" do
      MockSettings['scripts'] = [{ name: 'myscript', args: [] }]
      MockScript.set_running('myscript', true)

      run_generic_autostart_loop
      expect(MockScript.started).to be_empty
    end
  end

  describe "dedup across registries" do
    it "only starts a script once when it appears in both Settings and CharSettings" do
      MockSettings['scripts'] = [{ name: 'shared', args: [] }]
      MockCharSettings['scripts'] = [{ name: 'shared', args: [] }]

      # The first start will succeed; the second iteration should see it
      # as "started" only if the mock tracks it.  Since our mock does not
      # auto-set running? after start, we simulate the real behavior:
      # the Script.running? guard will be false both times unless we
      # manually flag it.  In production Lich, Script.start makes it
      # running.  We test that the guard is present by marking it running
      # after the first call.
      allow(MockScript).to receive(:start).and_wrap_original do |meth, *args, **kwargs|
        meth.call(*args, **kwargs)
        MockScript.set_running(args.first, true)
      end

      run_generic_autostart_loop
      expect(MockScript.started.size).to eq(1)
    end
  end

  describe "empty / nil lists" do
    it "handles nil Settings['scripts'] without error" do
      MockSettings['scripts'] = nil
      MockCharSettings['scripts'] = nil

      expect { run_generic_autostart_loop }.not_to raise_error
      expect(MockScript.started).to be_empty
    end

    it "handles empty array Settings['scripts'] without error" do
      MockSettings['scripts'] = []
      MockCharSettings['scripts'] = []

      expect { run_generic_autostart_loop }.not_to raise_error
      expect(MockScript.started).to be_empty
    end
  end

  describe "non-array Settings['scripts']" do
    it "does not iterate when Settings['scripts'] is a String" do
      MockSettings['scripts'] = "not_an_array"

      expect { run_generic_autostart_loop }.not_to raise_error
      expect(MockScript.started).to be_empty
    end

    it "does not iterate when Settings['scripts'] is a Hash" do
      MockSettings['scripts'] = { name: 'sneaky', args: [] }

      expect { run_generic_autostart_loop }.not_to raise_error
      expect(MockScript.started).to be_empty
    end
  end

  describe "skipped scripts" do
    it "skips infomon" do
      MockSettings['scripts'] = [{ name: 'infomon', args: [] }]

      run_generic_autostart_loop
      expect(MockScript.started).to be_empty
    end

    it "skips repository" do
      MockSettings['scripts'] = [{ name: 'repository', args: [] }]

      run_generic_autostart_loop
      expect(MockScript.started).to be_empty
    end

    it "skips dependency" do
      MockSettings['scripts'] = [{ name: 'dependency', args: [] }]

      run_generic_autostart_loop
      expect(MockScript.started).to be_empty
    end

    it "skips lich5-update when LICH_VERSION > 5.6.2" do
      MockSettings['scripts'] = [{ name: 'lich5-update', args: [] }]

      run_generic_autostart_loop(lich_version: "5.7.0")
      expect(MockScript.started).to be_empty
    end
  end

  describe "DR dependency removal" do
    it "removes dependency from Settings list for DR game" do
      MockXMLData.game = "DRF"
      MockSettings['scripts'] = [{ name: 'dependency', args: [] }]
      output = []

      run_generic_autostart_loop(respond_output: output)
      expect(output).to include("dependency removed")
      expect(MockSettings['scripts']).not_to include(a_hash_including(name: 'dependency'))
    end

    it "removes dependency from CharSettings list for DR game" do
      MockXMLData.game = "DRX"
      MockCharSettings['scripts'] = [{ name: 'dependency', args: [] }]
      output = []

      run_generic_autostart_loop(respond_output: output)
      expect(output).to include("dependency removed")
      expect(MockCharSettings['scripts']).not_to include(a_hash_including(name: 'dependency'))
    end

    it "does NOT remove dependency for non-DR game (still skips it)" do
      MockXMLData.game = "GSIV"
      MockSettings['scripts'] = [{ name: 'dependency', args: [] }]

      run_generic_autostart_loop
      # dependency is skipped but not removed for non-DR games
      expect(MockSettings['scripts']).to include(a_hash_including(name: 'dependency'))
      expect(MockScript.started).to be_empty
    end
  end

  describe "edge case: script_info with empty args" do
    it "starts a script passing empty args array" do
      MockSettings['scripts'] = [{ name: 'noargs', args: [] }]

      run_generic_autostart_loop
      expect(MockScript.started).to eq([{ name: 'noargs', args: [] }])
    end

    it "starts a script passing nil args" do
      MockSettings['scripts'] = [{ name: 'nilargs', args: nil }]

      run_generic_autostart_loop
      expect(MockScript.started).to eq([{ name: 'nilargs', args: nil }])
    end
  end
end
