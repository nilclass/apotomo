require 'onfire'

module Apotomo
  class StatefulWidget < Cell::Base

    class_inheritable_array :initialize_hooks, :instance_writer => false
    self.initialize_hooks = []

    attr_accessor :opts
    attr_writer   :visible

    include TreeNode
    include Persistence

    include Onfire

    include EventMethods
    include Transition
    include Caching

    include DeepLinkMethods

    helper Apotomo::Rails::ViewHelper


    attr_writer   :controller
    attr_accessor :version


    # Constructor which needs a unique id for the widget and one or multiple start states.
    # <tt>start_state</tt> may be a symbol or an array of symbols.
    def initialize(id, start_state, opts={})
      @opts         = opts
      @name         = id
      @start_state  = start_state

      @visible      = true
      @version      = 0

      @cell         = self

      process_initialize_hooks(id, start_state, opts)

      yield(self) if block_given?
    end

    def process_initialize_hooks(*args)
      self.class.initialize_hooks.each { |h| send(h, *args) }
    end

    def last_state
      @state_name
    end

    def visible?
      @visible
    end

    # Defines the instance vars that should <em>not</em> survive between requests,
    # which means they're not frozen in Apotomo::StatefulWidget#freeze.
    def ivars_to_forget
      unfreezable_ivars
    end

    def unfreezable_ivars
      ['@childrenHash', '@children', '@parent', '@controller', '@cell', '@invoke_block', '@ivars_before', '@rendered_children', '@page_updates', '@opts']
    end

    # Defines the instance vars which should <em>not</em> be copied to the view.
    # Called in Cell::Base.
    def ivars_to_ignore
      []
    end


    # Returns the rendered content for the widget by running the state method for <tt>state</tt>.
    # This might lead us to some other state since the state method could call #jump_to_state.
    def invoke(state=nil, &block)
      @invoke_block = block ### DISCUSS: store block so we don't have to pass it 10 times?
      logger.debug "\ninvoke on #{name} with #{state.inspect}"

      if state.blank?
        state = next_state_for(last_state) || @start_state
      end

      logger.debug "#{name}: transition: #{last_state} to #{state}"
      logger.debug "                                    ...#{state}"

      render_state(state)
    end



    # called in Cell::Base#render_state
    def dispatch_state(state)
      send(state, &@invoke_block)
    end


    # Render the view for the current state. Usually called at the end of a state method.
    #
    # ==== Options
    # * <tt>:view</tt> - Specifies the name of the view file to render. Defaults to the current state name.
    # * <tt>:template_format</tt> - Allows using a format different to <tt>:html</tt>.
    # * <tt>:layout</tt> - If set to a valid filename inside your cell's view_paths, the current state view will be rendered inside the layout (as known from controller actions). Layouts should reside in <tt>app/cells/layouts</tt>.
    # * <tt>:html_options</tt> - Pass a hash to add html attributes like +class+ or +style+ to the widgets' surrounding div.
    # * <tt>:js</tt> - Executes the string as JavaScript on the page. If set, no view will be rendered.
    # * <tt>:raw</tt> - Will send the string directly to the browser, no view will be rendered.
    # * <tt>:replace_html</tt> - If true, the new content will replace the innerHtml of the widget's div. Defaults to false, which replaces the complete div.
    # * <tt>:render_children</tt> - If false, automatic rendering of child widgets is turned off. Defaults to true.
    # * <tt>:frame</tt> - If false, automatic framing of the widget is turned off. Pass some valid tag name if you prefer some other container tag in place of the div.
    # * <tt>:invoke</tt> - Explicitly define the state to be invoked on a child when rendering.
    # * see Cell::Base#render for additional options
    #
    # Note that <tt>:text => ...</tt> and <tt>:replace_html => true</tt> will turn off <tt>:frame</tt>.
    #
    # Example:
    #  class MouseCell < Apotomo::StatefulWidget
    #    def eating
    #      # ... do something
    #      render
    #    end
    #
    # will just render the view <tt>eating.html</tt>.
    #
    #    def eating
    #      # ... do something
    #      render :view => :bored, :layout => "metal"
    #    end
    #
    # will use the view <tt>bored.html</tt> as template and even put it in the layout
    # <tt>metal</tt> that's located at <tt>$RAILS_ROOT/app/cells/layouts/metal.html.erb</tt>.
    #
    #  render :js => "alert('SQUEAK!');"
    #
    # issues a squeaking alert dialog on the page.
    #
    #  render :html_options => {:class => :highlighted}
    # will result in
    #  <div id="mouse" class="highlighted"...>
    #
    #  render :frame => :p
    # will result in
    #  <p id="mouse">...</p>
    def render(options={})
      if options[:text] or options[:replace_html] # per default, disable framing for :text/:replace_html
        options.reverse_merge!(:frame => false)
      end

      options.reverse_merge!  :render_children  => true,
                              :frame            => :div,
                              :html_options     => {},
                              :locals           => {},
                              :replace_html     => false,
                              :invoke           => {}


      rendered_children = render_children_for(options)

      options[:html_options].reverse_merge!(:id => name)
      options[:locals].reverse_merge!(:rendered_children => rendered_children)

      @controller = controller # that dependency SUCKS.


      ### DISCUSS: provide a better JS abstraction API and de-coupled helpers like #visual_effect.
      if content = options[:js]
        return ::Apotomo::Content::Javascript.new(content)
      end

      if content = options[:raw]
        return ::Apotomo::Content::Raw.new(content)
      end

      if options[:nothing]
        return ""
      end


      content = render_view_for(options, @state_name) # defined in Cell::Base.
      content = frame_content_for(content, options)

      page_update_for(content, options[:replace_html])
    end

    def page_update_for(content, replace_html)
      mode = replace_html ? :replace_html : :replace
      ::Apotomo::Content::PageUpdate.new(mode => name, :with => content)
    end

    # Wrap the content into a div frame.
    def frame_content_for(content, options)
      return content unless options[:frame]

      ### TODO: i'd love to see a real API for helpers in rails.
      Object.new.extend(ActionView::Helpers::TagHelper).content_tag(options[:frame], content, options[:html_options])
    end


    # Force the FSM to go into <tt>state</tt>, regardless whether it's a valid
    # transition or not.
    ### TODO: document the need for return.
    def jump_to_state(state)
      logger.debug "STATE JUMP! to #{state}"

      render_state(state)
    end


    def visible_children
      children.find_all { |kid| kid.visible? }
    end

    def render_children_for(options)
      return {} unless options[:render_children]

      render_children(options[:invoke])
    end

    def render_children(invoke_options={})
      returning rendered_children = ActiveSupport::OrderedHash.new do
        visible_children.each do |kid|
          child_state = decide_state_for(kid, invoke_options)
          logger.debug "    #{kid.name} -> #{child_state}"

          rendered_children[kid.name] = render_child(kid, child_state)
        end
      end
    end

    def render_child(cell, state)
     cell.invoke(state)
    end

    def decide_state_for(child, invoke_options)
      invoke_options.stringify_keys[child.name.to_s]
    end


    ### DISCUSS: use #param only for accessing request data.
    def param(name)
      params[name]
    end


    # Returns the address hash to the event controller and the targeted widget.
    #
    # Reserved options for <tt>way</tt>:
    #   :source   explicitly specifies an event source.
    #             The default is to take the current widget as source.
    #   :type     specifies the event type.
    #
    # Any other option will be directly passed into the address hash and is
    # available via StatefulWidget#param in the widget.
    #
    # Can be passed to #url_for.
    #
    # Example:
    #   address_for_event :type => :squeak, :volume => 9
    # will result in an address that triggers a <tt>:click</tt> event from the current
    # widget and also provides the parameter <tt>:item_id</tt>.
    def address_for_event(options)
      raise "please specify the event :type" unless options[:type]

      options[:source] ||= self.name
      options
    end

    # Returns the widget named <tt>widget_id</tt> as long as it is below self or self itself.
    def find_widget(widget_id)
      find {|node| node.name.to_s == widget_id.to_s}
    end

    def controller
      isRoot? ? @controller : root.controller
    end
  end
end
