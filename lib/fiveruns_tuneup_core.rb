require 'erb'

module Fiveruns
  
  module Tuneup
    
    class CalculationError < ::RuntimeError; end
    
    class << self
      attr_accessor :javascripts_path
      attr_accessor :stylesheets_path
    end

    def self.record(&block)
      Step.reset!
      root = RootStep.new
      root.record(&block)
      root
    end

    def self.step(name, layer, extras = {}, &block)
      trace = format_caller(caller)
      Step.new(name, layer, extras.merge(:caller => trace), nil).record(&block)
    end

    def self.insert_panel(body, run)
      return body unless run
      tag = body[/(<body[^>]*>)/i, 1]
      return body unless tag
      panel = Panel.new(run)
      body.sub(/<\/head>/i, head << '</head>').sub(tag, tag + panel.to_html)
    end

    def self.head
      %(
        <script src='#{javascripts_path}/init.js' type='text/javascript'></script>
        <link rel='stylesheet' type='text/css' href='#{stylesheets_path}/tuneup.css'/>
      )
    end
    
    def self.format_caller(trace)
      valid_lines = trace.reject { |line| line =~ /fiveruns_tuneup/ }[0,5]
      linked_lines = valid_lines.map { |line| editor_link_line(line) }
      '<pre>%s</pre>' % linked_lines.join("\n")
    end
    
    def self.editor_link_line(line)
      filename, number, extra = line.match(/^(.+?):(\d+):in\b(.*?)/)[1, 2]
      name = if line.size > 87
        "&hellip;#{CGI.escapeHTML line.sub(/^.*?(.{40})$/, '\1')}"
      else
        line
      end
      name.sub!(/([^\/\\]+\.rb:.*)$/, '<span>\1</span>')
      %(<a title='%s' href='txmt://open/?url=file://%s&line=%d'>%s</a>%s) % [CGI.escapeHTML(line), filename, number, name, extra]
    end
    
    module Templating
      
      def h(text)
        CGI.escapeHTML(text)
      end
      
      def to_html
        ERB.new(template).result(binding)
      end
      
    end
      
    class RootStep
      include Templating
      attr_reader :children, :bar
      attr_accessor :time, :parent
      def initialize(time = nil)
        @time = time
        @children = []
        @bar = Bar.new(self)
      end
      
      def root
        parent ? parent.root : self
      end
      
      def record
        start = Time.now
        result = Step.inside(self) { yield }
        @time = Time.now - start
        result
      end
      def disparity
        result = time - children.inject(0) { |sum, child| sum + child.time }
        if result < 0
          raise CalculationError, "Child steps exceed parent step size"
        end
        result
      end
      def add_child(child)
        child.parent = self
        children << child
      end
      def format_time(time)
        '%.1fms' % (time * 1000)
      end
      def layer_portions
        children.first.layer_portions
      end
      def to_json
        {:children => children, :time => time}.to_json
      end
      
      def proportion
        time / root.time
      end

      def template
        %(
          <div id="tuneup-summary">
            <%= bar.to_html %>
            <%= (time * 1000).to_i %> ms
          </div>
        )
      end

    end

    class Step < RootStep

      def self.stack
        @stack ||= []
      end

      def self.reset!
        stack.clear
      end

      def self.inside(step)
        unless stack.empty?
          stack.last.add_child(step)
        end
        stack << step
        result = yield
        stack.pop
        result
      end

      attr_reader :name, :layer, :extras
      def initialize(name, layer, extras = {}, time = nil)
        super(time)
        @name = name
        @layer = layer
        @extras = extras
      end

      def children_with_disparity
        return children if children.empty?
        layer_name = layer if respond_to?(:layer)
        extra_step = Step.new('(Other)', layer_name, {}, disparity)
        extra_step.parent = parent
        children + [extra_step]
      end

      def layer_portions
        @layer_portions ||= begin
          result = {:model => 0, :view => 0, :controller => 0}
          if children.empty?
            result[layer] = 1
          else
            times = children.inject({}) do |totals, child|
              totals[child.layer] ||= 0
              totals[child.layer] += child.time
              totals
            end
            times[layer] ||= 0
            times[layer] += disparity
            times.inject(result) do |all, (l, t)|
              result[l] = t / time
              result            
            end
          end
          result
        end
      end
      
      def to_json
        {:children => children_with_disparity, :time => time}.to_json
      end
      
      def template
        %(
          <li class="<%= html_class %>">
            <ul class="tuneup-step-info">
              <li class="tuneup-title">
                <span class="time"><%= '%.1f' % (time * 1000) %> ms</span>
                <a class='tuneup-step-name' title="<%=h name %>"><%=h name %></a>
                <a class='tuneup-step-extras-link'>(?)</a>
              </li>
              <li class="tuneup-detail-bar"><%= bar.to_html %></li>
              <li style="clear: both;"/>
           </ul>
           <div class='tuneup-step-extras'>
             <dl>
               <% extras.each do |key, value| %>
                 <dt><%=h key.to_s.capitalize %></dt>
                 <dd><%= value.to_s %></dd>
               <% end %>
             </dl>
           </div>
           <%= html_children %>
          </li>
        )
      end
      
      private
      
      def html_class
        %W(fiveruns_tuneup_step #{'with_children' if children.any?} #{'tuneup-opened' if root.children.first.object_id == self.object_id}).compact.join(' ')
      end
      
      def html_children
        return unless children.any?
        %(<ul class='fiveruns_tuneup_children'>%s</ul>) % children_with_disparity.map { |child| child.to_html }.join
      end

    end
    
    class Bar
      include Templating
      
      attr_reader :step
      def initialize(step)
        @step = step
      end
      
      private
      
      def template
        %(
          <ul id="<%= 'tuneup-root-bar' if step.is_a?(RootStep) %>" class="tuneup-bar">
            <% %w(model view controller).each do |layer| %>
              <%= component layer %>
            <% end %>
          </ul>
        )
      end
      
      def component(layer)
        width = width_of(layer)
        %(
          <li title="#{layer.to_s.capitalize}" style="width: #{width}px;" class="tuneup-layer-#{layer}">#{layer.to_s[0,1].capitalize if width >= 12}</li>
        )
      end
      
      def width_of(layer)
        portion = step.layer_portions[layer.to_sym]
        result = portion * 200 * step.proportion
        result < 1 && portion != 0 ? 1 : result
      end
      
    end
    
    class Panel
      include Templating
      
      attr_reader :root
      def initialize(root)
        @root = root
      end
      
      private
      
      def template
        %(
          <div id="tuneup"><h1>FiveRuns TuneUp</h1><img alt="" src="/images/tuneup/spinner.gif" style="display: none;" id="tuneup_spinner"/><div style="display: block;" id="tuneup-content"><div id="tuneup-panel">
            <div id="tuneup-data">
            <div id="tuneup-top">
              <%= root.to_html %>
              <%# In later version... %>
              <!-- <a href="#" id="tuneup-save-link">Share this Run</a> -->
            </div>
            <ul id="tuneup-details">
              <% root.children.each do |child| %>
                <%= child.to_html %>
              <% end %>
              <li style="clear: both;"/>
              <li style="padding-top: 10px; font-style: italic; float: right; font-size: 0.8em; color: rgb(204, 204, 204);">
                See our 
                <a style="font-style: italic;" target="_blank" href="http://www.fiveruns.com/products">production monitoring products</a>.
              </li>
            </ul>
          </div>
          </div></div></div>
        )
      end
      
    end
  
  end
      
end