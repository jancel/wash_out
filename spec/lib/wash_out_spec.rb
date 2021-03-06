#encoding:utf-8

require 'spec_helper'

describe WashOut do
  before :each do
    WashOut::Engine.snakecase_input = true
    WashOut::Engine.camelize_wsdl   = true
    WashOut::Engine.namespace       = false
  end

  let :nori do
    Nori.new(
      :strip_namespaces => true,
      :advanced_typecasting => true,
      :convert_tags_to => lambda {|x| x.snakecase.to_sym}
    )
  end

  def savon(method, message={}, &block)
    message = {:value => message} unless message.is_a?(Hash)

    savon = Savon::Client.new(:log => false, :wsdl => 'http://app/api/wsdl', &block)
    savon.call(method, :message => message).to_hash
  end

  describe "Module" do
    it "includes" do
      lambda {
        mock_controller do
          # nothing
        end
      }.should_not raise_exception
    end

    it "allows definition of a simple action" do
      lambda {
        mock_controller do
          soap_action "answer", :args => nil, :return => :integer
        end
      }.should_not raise_exception
    end
  end

  describe "WSDL" do
    let :wsdl do
      mock_controller do
        soap_action :result, :args => nil, :return => :int

        soap_action "getArea", :args   => { :circle => { :center => { :x => [:integer],
                                                                      :y => :integer },
                                                         :radius => :double } },
                               :return => { :area => :double }

        soap_action "rocky", :args   => { :circle1 => { :x => :integer } },
                             :return => { :circle2 => { :y => :integer } }
      end

      HTTPI.get("http://app/api/wsdl").body
    end

    let :xml do
      nori.parse wsdl
    end

    it "lists operations" do
      operations = xml[:definitions][:binding][:operation]
      operations.should be_a_kind_of(Array)

      operations.map{|e| e[:'@name']}.sort.should == ['Result', 'getArea', 'rocky'].sort
    end

    it "defines complex types" do
      wsdl.include?('<xsd:complexType name="Circle1">').should == true
    end

    it "defines arrays" do
      x = xml[:definitions][:types][:schema][:complex_type].
        find{|x| x[:'@name'] == 'Center'}[:sequence][:element].
        find{|x| x[:'@name'] == 'X'}

      x[:'@min_occurs'].should == "0"
      x[:'@max_occurs'].should == "unbounded"
    end
  end

  describe "Dispatcher" do

    context "simple actions" do
      it "accept no parameters" do
        mock_controller do
          soap_action "answer", :args => nil, :return => :int
          def answer
            render :soap => "42"
          end
        end

        savon(:answer)[:answer_response][:value].
          should == "42"
      end

      it "accept insufficient parameters" do
        mock_controller do
          soap_action "answer", :args => {:a => :integer}, :return => :integer
          def answer
            render :soap => "42"
          end
        end

        savon(:answer)[:answer_response][:value].
          should == "42"
      end

      it "accept empty parameter" do
        mock_controller do
          soap_action "answer", :args => {:a => :string}, :return => {:a => :string}
          def answer
            render :soap => {:a => params[:a]}
          end
        end
        savon(:answer, :a => '')[:answer_response][:a].
          should == {:"@xsi:type"=>"xsd:string"}
      end

      it "accept one parameter" do
        mock_controller do
          soap_action "checkAnswer", :args => :integer, :return => :boolean, :to => 'check_answer'
          def check_answer
            render :soap => (params[:value] == 42)
          end
        end

        savon(:check_answer, 42)[:check_answer_response][:value].should == true
        savon(:check_answer, 13)[:check_answer_response][:value].should == false
      end

      it "accept two parameters" do
        mock_controller do
          soap_action "funky", :args => { :a => :integer, :b => :string }, :return => :string
          def funky
            render :soap => ((params[:a] * 10).to_s + params[:b])
          end
        end

        savon(:funky, :a => 42, :b => 'k')[:funky_response][:value].should == '420k'
      end
    end

    context "complex actions" do
      it "accept nested structures" do
        mock_controller do
          soap_action "getArea", :args   => { :circle => { :center => { :x => :integer,
                                                                        :y => :integer },
                                                           :radius => :double } },
                                 :return => { :area => :double,
                                              :distance_from_o => :double },
                                 :to     => :get_area
          def get_area
            circle = params[:circle]
            render :soap => { :area            => Math::PI * circle[:radius] ** 2,
                              :distance_from_o => Math.sqrt(circle[:center][:x] ** 2 + circle[:center][:y] ** 2) }
          end
        end

        message = { :circle => { :center => { :x => 3, :y => 4 },
                                 :radius => 5 } }

        savon(:get_area, message)[:get_area_response].
          should == ({ :area => (Math::PI * 25).to_s, :distance_from_o => (5.0).to_s })
      end

      it "accept arrays" do
        mock_controller do
          soap_action "rumba",
                      :args   => {
                        :rumbas => [:integer]
                      },
                      :return => nil
          def rumba
            params.should == {"rumbas" => [1, 2, 3]}
            render :soap => nil
          end
        end

        savon(:rumba, :rumbas => [1, 2, 3])
      end

      it "accept nested structures inside arrays" do
        mock_controller do
          soap_action "rumba",
                      :args   => {
                        :rumbas => [ {
                          :zombies => :string,
                          :puppies => :string
                        } ]
                      },
                      :return => nil
          def rumba
            params.should == {
              "rumbas" => [
                {"zombies" => 'suck', "puppies" => 'rock'},
                {"zombies" => 'slow', "puppies" => 'fast'}
              ]
            }
            render :soap => nil
          end
        end

        savon :rumba, :rumbas => [
          {:zombies => 'suck', :puppies => 'rock'},
          {:zombies => 'slow', :puppies => 'fast'}
        ]
      end

      it "respond with nested structures" do
        mock_controller do
          soap_action "gogogo",
                      :args   => nil,
                      :return => {
                        :zoo => :string,
                        :boo => { :moo => :string, :doo => :string }
                      }
          def gogogo
            render :soap => {
              :zoo => 'zoo',
              :boo => { :moo => 'moo', :doo => 'doo' }
            }
          end
        end

        savon(:gogogo)[:gogogo_response].
          should == {:zoo=>"zoo", :boo=>{:moo=>"moo", :doo=>"doo", :"@xsi:type"=>"tns:Boo"}}
      end

      it "respond with arrays" do
        mock_controller do
          soap_action "rumba",
                      :args   => nil,
                      :return => [:integer]
          def rumba
            render :soap => [1, 2, 3]
          end
        end

        savon(:rumba)[:rumba_response].should == {:value => ["1", "2", "3"]}
      end

      it "respond with complex structures inside arrays" do
        mock_controller do
          soap_action "rumba",
            :args   => nil,
            :return => {
              :rumbas => [{:zombies => :string, :puppies => :string}]
            }
          def rumba
            render :soap =>
              {:rumbas => [
                  {:zombies => "suck1", :puppies => "rock1" },
                  {:zombies => "suck2", :puppies => "rock2" }
                ]
              }
          end
        end

        savon(:rumba)[:rumba_response].should == {
          :rumbas => [
            {:zombies => "suck1",:puppies => "rock1", :"@xsi:type"=>"tns:Rumbas"},
            {:zombies => "suck2", :puppies => "rock2", :"@xsi:type"=>"tns:Rumbas" }
          ]
        }
      end

      it "respond with structs in structs in arrays" do
        mock_controller do
          soap_action "rumba",
            :args => nil,
            :return => [{:rumbas => {:zombies => :integer}}]

          def rumba
            render :soap => [{:rumbas => {:zombies => 100000}}, {:rumbas => {:zombies => 2}}]
          end
        end

        savon(:rumba)[:rumba_response].should == {
          :value => [
            {
              :rumbas => {
                :zombies => "100000",
                :"@xsi:type" => "tns:Rumbas"
              },
              :"@xsi:type" => "tns:Value"
            },
            {
              :rumbas => {
                :zombies => "2",
                :"@xsi:type" => "tns:Rumbas"
              },
              :"@xsi:type"=>"tns:Value"
            }
          ]
        }
      end

      context "with arrays missing" do
        it "respond with simple definition" do
          mock_controller do
            soap_action "rocknroll",
                        :args => nil, :return => { :my_value => [:integer] }
            def rocknroll
              render :soap => {}
            end
          end

          savon(:rocknroll)[:rocknroll_response].should be_nil
        end

        it "respond with complext definition" do
          mock_controller do
            soap_action "rocknroll",
                        :args => nil, :return => { :my_value => [{ :value => :integer}] }
            def rocknroll
              render :soap => {}
            end
          end

          savon(:rocknroll)[:rocknroll_response].should be_nil
        end

        it "respond with nested simple definition" do
          mock_controller do
            soap_action "rocknroll",
                        :args => nil, :return => { :my_value => { :my_array => [{ :value => :integer}] } }
            def rocknroll
              render :soap => {}
            end
          end

          savon(:rocknroll)[:rocknroll_response][:my_value].
            should == { :"@xsi:type" => "tns:MyValue" }
        end
      end
    end

    context "types" do
      it "recognize boolean" do
        mock_controller do
          soap_action "true", :args => :boolean, :return => :nil
          def true
            params[:value].should == true
            render :soap => nil
          end

          soap_action "false", :args => :boolean, :return => :nil
          def false
            params[:value].should == false
            render :soap => nil
          end
        end

        savon(:true, :value => true)
        savon(:false, :value => false)
      end

      it "recognize dates" do
        mock_controller do
          soap_action "date", :args => :date, :return => :nil
          def date
            params[:value].should == Date.parse('2000-12-30') unless params[:value].blank?
            render :soap => nil
          end
        end

        savon(:date, :value => '2000-12-30')
        lambda { savon(:date) }.should_not raise_exception
      end
    end

    context "errors" do
      it "raise for incorrect requests" do
        mock_controller do
          soap_action "duty", 
            :args => {:bad => {:a => :string, :b => :string}, :good => {:a => :string, :b => :string}},
            :return => nil
          def duty
            render :soap => nil
          end
        end

        lambda {
          savon(:duty, :bad => 42, :good => nil)
        }.should raise_exception(Savon::SOAPFault)
      end

      it "raise to report SOAP errors" do
        mock_controller do
          soap_action "error", :args => { :need_error => :boolean }, :return => nil
          def error
            raise self.class.const_get(:SOAPError), "you wanted one" if params[:need_error]
            render :soap => nil
          end
        end

        lambda { savon(:error, :need_error => false) }.should_not raise_exception
        lambda { savon(:error, :need_error => true) }.should raise_exception(Savon::SOAPFault)
      end

      # TODO: New Savon doesn't allow you to call methods that are not available among WSDL
      xit "raise for nonexistent method" do
        mock_controller

        lambda { savon(:nonexistent) }.should raise_exception(Savon::SOAPFault)
      end

      it "raise for manual throws" do
        mock_controller do
          soap_action "error", :args => nil, :return => nil
          def error
            render_soap_error "a message"
          end
        end

        lambda { savon(:error) }.should raise_exception(Savon::SOAPFault)
      end

      it "raise when response structure mismatches" do
        mock_controller do
          soap_action 'bad', :args => :integer, :return => {
            :basic => :string,
            :stallions => {
              :stallion => [
                :name => :string,
                :wyldness => :integer,
              ]
            },
          }
          def bad
            render :soap => {
              :basic => 'hi',
              :stallions => [{:name => 'ted', :wyldness => 11}]
            }
          end

          soap_action 'bad2', :args => :integer, :return => {
            :basic => :string,
            :telephone_booths => [:string]
          }
          def bad2
            render :soap => {
              :basic => 'hihi',
              :telephone_booths => 'oops'
            }
          end
        end

        lambda { savon(:bad) }.should raise_exception(
          WashOut::Dispatcher::ProgrammerError,
          /SOAP response .*wyldness.*Array.*Hash.*stallion/
        )

        lambda { savon(:bad2) }.should raise_exception(
          WashOut::Dispatcher::ProgrammerError,
          /SOAP response .*oops.*String.*telephone_booths.*Array/
        )
      end
    end

    context "deprecates" do
      it "old syntax" do
        # save rspec context check
        raise_runtime_exception = raise_exception(RuntimeError)

        mock_controller do
          lambda {
            soap_action "rumba",
                        :args   => :integer,
                        :return => []
          }.should raise_runtime_exception
          def rumba
            render :soap => nil
          end
        end
      end
    end

    it "allows arbitrary action names" do
      name = 'AnswerToTheUltimateQuestionOfLifeTheUniverseAndEverything'

      mock_controller do
        soap_action name, :args => nil, :return => :integer, :to => :answer
        def answer
          render :soap => "forty two"
        end
      end

      savon(name.underscore.to_sym)["#{name.underscore}_response".to_sym][:value].
        should == "forty two"
    end

    it "respects :response_tag option" do
      mock_controller do
        soap_action "specific", :response_tag => "test", :return => :string
        def specific
          render :soap => "test"
        end
      end

      savon(:specific).should == {:test => {:value=>"test"}}
    end

    it "handles snakecase option properly" do
      WashOut::Engine.snakecase_input = false
      WashOut::Engine.camelize_wsdl   = false

      mock_controller do
        soap_action "rocknroll", :args => {:ZOMG => :string}, :return => nil
        def rocknroll
          params["ZOMG"].should == "yam!"
          render :soap => nil
        end
      end

      savon(:rocknroll, "ZOMG" => 'yam!')
    end

  end

  describe "WS Security" do

    it "appends username_token to params" do
      WashOut::Engine.wsse_username = nil
      WashOut::Engine.wsse_password = nil

      mock_controller do
        soap_action "checkToken", :args => :integer, :return => nil, :to => 'check_token'
        def check_token
          request.env['WSSE_TOKEN']['username'].should == "gorilla"
          request.env['WSSE_TOKEN']['password'].should == "secret"
          render :soap => nil
        end
      end

      savon(:check_token, 42) do
        wsse_auth "gorilla", "secret"
      end
    end

    it "handles PasswordText auth" do
      WashOut::Engine.wsse_username = "gorilla"
      WashOut::Engine.wsse_password = "secret"

      mock_controller do
        soap_action "checkAuth", :args => :integer, :return => :boolean, :to => 'check_auth'
        def check_auth
          render :soap => (params[:value] == 42)
        end
      end

      # correct auth
      lambda { savon(:check_auth, 42){ wsse_auth "gorilla", "secret" } }.
        should_not raise_exception

      # wrong user
      lambda { savon(:check_auth, 42){ wsse_auth "chimpanzee", "secret" } }.
        should raise_exception(Savon::SOAPFault)

      # wrong pass
      lambda { savon(:check_auth, 42){ wsse_auth "gorilla", "nicetry" } }.
        should raise_exception(Savon::SOAPFault)

      # no auth
      lambda { savon(:check_auth, 42) }.
        should raise_exception(Savon::SOAPFault)
    end

    it "handles PasswordDigest auth" do
      WashOut::Engine.wsse_username = "gorilla"
      WashOut::Engine.wsse_password = "secret"

      mock_controller do
        soap_action "checkAuth", :args => :integer, :return => :boolean, :to => 'check_auth'
        def check_auth
          render :soap => (params[:value] == 42)
        end
      end

      # correct auth
      lambda { savon(:check_auth, 42){ wsse_auth "gorilla", "secret", :digest } }.
        should_not raise_exception

      # wrong user
      lambda { savon(:check_auth, 42){ wsse_auth "chimpanzee", "secret", :digest } }.
        should raise_exception(Savon::SOAPFault)

      # wrong pass
      lambda { savon(:check_auth, 42){ wsse_auth "gorilla", "nicetry", :digest } }.
        should raise_exception(Savon::SOAPFault)

      # no auth
      lambda { savon(:check_auth, 42) }.
        should raise_exception(Savon::SOAPFault)
    end

  end

end
