require 'spec_helper'

module Rack
  module Session
    describe "Rack::Session::Redis" do
      before(:each) do
        @session_key = Rack::Session::Redis::DEFAULT_OPTIONS[:key]
        @session_match = /#{@session_key}=[0-9a-fA-F]+;/
        @incrementor = lambda do |env|
          env["rack.session"]["counter"] ||= 0
          env["rack.session"]["counter"] += 1
          Rack::Response.new(env["rack.session"].inspect).to_a
        end
        @drop_session = proc do |env|
          env['rack.session.options'][:drop] = true
          @incrementor.call(env)
        end
        @renew_session = proc do |env|
          env['rack.session.options'][:renew] = true
          @incrementor.call(env)
        end
        @defer_session = proc do |env|
          env['rack.session.options'][:defer] = true
          @incrementor.call(env)
        end
      end

      it "should specify connection params" do
        pool = Rack::Session::Redis.new(@incrementor, :redis_server => "localhost:6380/1/theplaylist").pool
        pool.should be_kind_of(::Redis::Store)
        pool.to_s.should == "Redis Client connected to localhost:6380 against DB 1 with namespace theplaylist"

        pool = Rack::Session::Redis.new(@incrementor, :redis_server => ["localhost:6379", "localhost:6380"]).pool
        pool.should be_kind_of(::Redis::DistributedStore)
      end

      it "creates a new cookie" do
        pool = Rack::Session::Redis.new(@incrementor)
        res = Rack::MockRequest.new(pool).get("/")
        res["Set-Cookie"].should match(/#{@session_key}=/)
        res.body.should == '{"counter"=>1}'
      end

      it "determines session from a cookie" do
        pool = Rack::Session::Redis.new(@incrementor)
        req = Rack::MockRequest.new(pool)
        res = req.get("/")
        cookie = res["Set-Cookie"]
        req.get("/", "HTTP_COOKIE" => cookie).body.should == '{"counter"=>2}'
        req.get("/", "HTTP_COOKIE" => cookie).body.should == '{"counter"=>3}'
      end

      it "survives nonexistant cookies" do
        bad_cookie = "rack.session=blarghfasel"
        pool = Rack::Session::Redis.new(@incrementor)
        res = Rack::MockRequest.new(pool).
          get("/", "HTTP_COOKIE" => bad_cookie)
        res.body.should == '{"counter"=>1}'
        cookie = res["Set-Cookie"][@session_match]
        cookie.should_not match(/#{bad_cookie}/)
      end

      it "should maintain freshness" do
        pool = Rack::Session::Redis.new(@incrementor, :expire_after => 3)
        res = Rack::MockRequest.new(pool).get('/')
        res.body.should include('"counter"=>1')
        cookie = res["Set-Cookie"]
        res = Rack::MockRequest.new(pool).get('/', "HTTP_COOKIE" => cookie)
        res["Set-Cookie"].should == cookie
        res.body.should include('"counter"=>2')
        puts 'Sleeping to expire session' if $DEBUG
        sleep 4
        res = Rack::MockRequest.new(pool).get('/', "HTTP_COOKIE" => cookie)
        res["Set-Cookie"].should_not == cookie
        res.body.should include('"counter"=>1')
      end

      it "deletes cookies with :drop option" do
        pool = Rack::Session::Redis.new(@incrementor)
        req = Rack::MockRequest.new(pool)
        drop = Rack::Utils::Context.new(pool, @drop_session)
        dreq = Rack::MockRequest.new(drop)

        res0 = req.get("/")
        session = (cookie = res0["Set-Cookie"])[@session_match]
        res0.body.should == '{"counter"=>1}'

        res1 = req.get("/", "HTTP_COOKIE" => cookie)
        res1["Set-Cookie"][@session_match].should == session
        res1.body.should == '{"counter"=>2}'

        res2 = dreq.get("/", "HTTP_COOKIE" => cookie)
        res2["Set-Cookie"].should be_nil
        res2.body.should == '{"counter"=>3}'

        res3 = req.get("/", "HTTP_COOKIE" => cookie)
        res3["Set-Cookie"][@session_match].should_not == session
        res3.body.should == '{"counter"=>1}'
      end

      it "provides new session id with :renew option" do
        pool = Rack::Session::Redis.new(@incrementor)
        req = Rack::MockRequest.new(pool)
        renew = Rack::Utils::Context.new(pool, @renew_session)
        rreq = Rack::MockRequest.new(renew)

        res0 = req.get("/")
        session = (cookie = res0["Set-Cookie"])[@session_match]
        res0.body.should == '{"counter"=>1}'

        res1 = req.get("/", "HTTP_COOKIE" => cookie)
        res1["Set-Cookie"][@session_match].should == session
        res1.body.should == '{"counter"=>2}'

        res2 = rreq.get("/", "HTTP_COOKIE" => cookie)
        new_cookie = res2["Set-Cookie"]
        new_session = new_cookie[@session_match]
        new_session.should_not == session
        res2.body.should == '{"counter"=>3}'

        res3 = req.get("/", "HTTP_COOKIE" => new_cookie)
        res3["Set-Cookie"][@session_match].should == new_session
        res3.body.should == '{"counter"=>4}'
      end

      specify "omits cookie with :defer option" do
        pool = Rack::Session::Redis.new(@incrementor)
        req = Rack::MockRequest.new(pool)
        defer = Rack::Utils::Context.new(pool, @defer_session)
        dreq = Rack::MockRequest.new(defer)

        res0 = req.get("/")
        session = (cookie = res0["Set-Cookie"])[@session_match]
        res0.body.should == '{"counter"=>1}'

        res1 = req.get("/", "HTTP_COOKIE" => cookie)
        res1["Set-Cookie"][@session_match].should == session
        res1.body.should == '{"counter"=>2}'

        res2 = dreq.get("/", "HTTP_COOKIE" => cookie)
        res2["Set-Cookie"].should be_nil
        res2.body.should == '{"counter"=>3}'

        res3 = req.get("/", "HTTP_COOKIE" => cookie)
        res3["Set-Cookie"][@session_match].should == session
        res3.body.should == '{"counter"=>4}'
      end

      # anyone know how to do this better?
      specify "multithread: should cleanly merge sessions" do
        next unless $DEBUG
        warn 'Running multithread test for Session::Redis'
        pool = Rack::Session::Redis.new(@incrementor)
        req = Rack::MockRequest.new(pool)

        res = req.get('/')
        res.body.should == '{"counter"=>1}'
        cookie = res["Set-Cookie"]
        sess_id = cookie[/#{pool.key}=([^,;]+)/,1]

        delta_incrementor = lambda do |env|
          # emulate disconjoinment of threading
          env['rack.session'] = env['rack.session'].dup
          Thread.stop
          env['rack.session'][(Time.now.usec*rand).to_i] = true
          @incrementor.call(env)
        end
        tses = Rack::Utils::Context.new pool, delta_incrementor
        treq = Rack::MockRequest.new(tses)
        tnum = rand(7).to_i+5
        r = Array.new(tnum) do
          Thread.new(treq) do |run|
            run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
          end
        end.reverse.map{|t| t.run.join.value }
        r.each do |res|
          res['Set-Cookie'].should == cookie
          res.body.should include('"counter"=>2')
        end

        session = pool.pool.get(sess_id)
        session.size.should == tnum+1 # counter
        session['counter'].should == 2 # meeeh

        tnum = rand(7).to_i+5
        r = Array.new(tnum) do |i|
          delta_time = proc do |env|
            env['rack.session'][i]  = Time.now
            Thread.stop
            env['rack.session']     = env['rack.session'].dup
            env['rack.session'][i] -= Time.now
            @incrementor.call(env)
          end
          app = Rack::Utils::Context.new pool, time_delta
          req = Rack::MockRequest.new app
          Thread.new(req) do |run|
            run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
          end
        end.reverse.map{|t| t.run.join.value }
        r.each do |res|
          res['Set-Cookie'].should == cookie
          res.body.should include('"counter"=>3')
        end

        session = pool.pool.get(sess_id)
        session.size.should == tnum+1
        session['counter'].should == 3

        drop_counter = proc do |env|
          env['rack.session'].del 'counter'
          env['rack.session']['foo'] = 'bar'
          [200, {'Content-Type'=>'text/plain'}, env['rack.session'].inspect]
        end
        tses = Rack::Utils::Context.new pool, drop_counter
        treq = Rack::MockRequest.new(tses)
        tnum = rand(7).to_i+5
        r = Array.new(tnum) do
          Thread.new(treq) do |run|
            run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
          end
        end.reverse.map{|t| t.run.join.value }
        r.each do |res|
          res['Set-Cookie'].should == cookie
          res.body.should include('"foo"=>"bar"')
        end

        session = pool.pool.get(sess_id)
        session.size.should == r.size+1
        session['counter'].should be_nil
        session['foo'].should == 'bar'
      end
    end
  end
end
