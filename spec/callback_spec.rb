require 'spec_helper'
require 'test_event'
require 'tmpdir'

RSpec.describe Debounced::Callback do
  describe '#call' do
    context 'static method' do
      it 'calls class method with no args' do
        # given
        allow(TestEvent).to receive(:publish4)
        # when
        described_class.new(class_name: 'TestEvent', method_name: 'publish4').call
        # then
        expect(TestEvent).to have_received(:publish4).with(no_args)
      end

      it 'calls class method with positional args' do
        # given
        allow(TestEvent).to receive(:publish2)
        # when
        described_class.new(class_name: 'TestEvent', method_name: 'publish2', args: ['hello']).call
        # then
        expect(TestEvent).to have_received(:publish2).with('hello')
      end
    end

    context 'instance method' do
      it 'calls instance method with initializer kwargs and no method args' do
        # given
        test_event = instance_double(TestEvent)
        allow(TestEvent).to receive(:new).and_return(test_event)
        allow(test_event).to receive(:publish1)
        # when
        described_class.new(class_name: 'TestEvent', method_name: 'publish1', kwargs: { test_id: 'abc' }).call
        # then
        expect(test_event).to have_received(:publish1).with(no_args)
      end

      it 'calls instance method with method_kwargs' do
        # given
        test_event = instance_double(TestEvent)
        allow(TestEvent).to receive(:new).and_return(test_event)
        allow(test_event).to receive(:publish3)
        # when
        described_class.new(
          class_name: 'TestEvent',
          method_name: 'publish3',
          kwargs: { test_id: 'abc' },
          method_kwargs: { label: 'my-label' },
        ).call
        # then
        expect(test_event).to have_received(:publish3) do |label:|
          expect(label).to eq('my-label')
        end
      end

      it 'calls instance method with positional method_args' do
        # given
        test_event = instance_double(TestEvent)
        allow(TestEvent).to receive(:new).and_return(test_event)
        allow(test_event).to receive(:publish5)
        # when
        described_class.new(
          class_name: 'TestEvent',
          method_name: 'publish5',
          kwargs: { test_id: 'abc' },
          method_args: ['my-label'],
        ).call
        # then
        expect(test_event).to have_received(:publish5) do |label|
          expect(label).to eq('my-label')
        end
      end

      it 'uses initializer kwargs for new and method_kwargs for send' do
        # given
        test_event = instance_double(TestEvent)
        allow(TestEvent).to receive(:new).and_return(test_event)
        allow(test_event).to receive(:publish3)
        # when
        described_class.new(
          class_name: 'TestEvent',
          method_name: 'publish3',
          kwargs: { test_id: 'my-id' },
          method_kwargs: { label: 'lbl' },
        ).call
        # then
        expect(TestEvent).to have_received(:new).with(test_id: 'my-id')
        expect(test_event).to have_received(:publish3) do |label:|
          expect(label).to eq('lbl')
        end
      end
    end

    context 'non-Callbackable class' do
      it 'logs warning when target class does not include Callbackable' do
        # given
        stub_const('NonCallbackable', Class.new)
        logger = instance_double(SemanticLogger::Logger, debug: nil)
        allow(logger).to receive(:warn)
        allow(Debounced.configuration).to receive(:logger).and_return(logger)
        # when
        described_class.new(class_name: 'NonCallbackable', method_name: 'run').call
        # then
        expect(logger).to have_received(:warn).with(/not an allowed Debounced callback target/)
      end
    end

    context 'methods that are not part of the target class API' do
      it 'refuses public reflection methods from core Ruby' do
        # given
        stub_const('Target', Class.new { include Debounced::Callbackable })
        # when
        described_class.new(class_name: 'Target', method_name: 'class_eval', args: ['$debounced_evaluated = true']).call
        # then
        expect($debounced_evaluated).to be_nil
      end
      
      it 'refuses private Kernel methods' do
        # given
        stub_const('Target', Class.new { include Debounced::Callbackable })
        marker = File.join(Dir.tmpdir, "debounced-system-#{Process.pid}")
        # when
        described_class.new(class_name: 'Target', method_name: 'system', method_args: ["touch #{marker}"]).call
        # then
        expect(File.exist?(marker)).to be(false)
      end
      
      it 'allows class methods added by an extended module' do
        # given
        enqueuing = Module.new { def perform_later(id) = id }
        stub_const('Target', Class.new { include Debounced::Callbackable; extend enqueuing })
        allow(Target).to receive(:perform_later).and_call_original
        # when
        described_class.new(class_name: 'Target', method_name: 'perform_later', args: [7]).call
        # then
        expect(Target).to have_received(:perform_later).with(7)
      end
    end
  end

  describe '.parse / #as_json round-trip' do
    it 'preserves full state through JSON serialization' do
      # given
      original = described_class.new(
        class_name: 'TestEvent',
        method_name: 'publish3',
        args: ['pos1', 2],
        kwargs: { test_id: 'x' },
        method_args: ['m1'],
        method_kwargs: { label: 'y' },
      )
      # when
      parsed = described_class.parse(JSON.parse(original.as_json.to_json))
      # then
      expect(parsed.class_name).to eq('TestEvent')
      expect(parsed.method_name).to eq('publish3')
      expect(parsed.args).to eq(['pos1', 2])
      expect(parsed.kwargs).to eq({ test_id: 'x' })
      expect(parsed.method_args).to eq(['m1'])
      expect(parsed.method_kwargs).to eq({ label: 'y' })
    end

    it 'preserves nested hash keys in kwargs through JSON serialization' do
      # given
      original = described_class.new(
        class_name: 'TestEvent',
        method_name: 'publish3',
        kwargs: { test_id: 'x', options: { retries: 3, tags: [{ name: 'a' }] } },
        method_kwargs: { label: 'y', meta: { source: 'test' } },
      )
      # when
      parsed = described_class.parse(JSON.parse(original.as_json.to_json))
      # then
      expect(parsed.kwargs).to eq({ test_id: 'x', options: { retries: 3, tags: [{ name: 'a' }] } })
      expect(parsed.method_kwargs).to eq({ label: 'y', meta: { source: 'test' } })
    end

    it 'parses legacy data missing method_args and method_kwargs' do
      data = {
        'class_name' => 'TestEvent',
        'method_name' => 'publish1',
        'args' => [],
        'kwargs' => {},
      }

      parsed = described_class.parse(data)

      expect(parsed.method_args).to eq([])
      expect(parsed.method_kwargs).to eq({})
    end

    it 'parses data missing args and kwargs entirely' do
      data = {
        'class_name' => 'TestEvent',
        'method_name' => 'publish1',
      }

      parsed = described_class.parse(data)

      expect(parsed.args).to eq([])
      expect(parsed.kwargs).to eq({})
      expect(parsed.method_args).to eq([])
      expect(parsed.method_kwargs).to eq({})
    end

    it 'parses data with explicit null args and kwargs' do
      data = {
        'class_name' => 'TestEvent',
        'method_name' => 'publish1',
        'args' => nil,
        'kwargs' => nil,
        'method_args' => nil,
        'method_kwargs' => nil,
      }

      parsed = described_class.parse(data)

      expect(parsed.args).to eq([])
      expect(parsed.kwargs).to eq({})
      expect(parsed.method_args).to eq([])
      expect(parsed.method_kwargs).to eq({})
    end
  end
end
