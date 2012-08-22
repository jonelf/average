require "rubygems"
require "sinatra"
require "datamapper"
require "haml"
require 'crypt/blowfish'
require 'base64'

DataMapper::setup(:default, ENV['DATABASE_URL'] || "mysql://root:CHANGETHIS@localhost/average")

class Average
  include DataMapper::Resource
  property :id, Integer, :serial => true
  property :name, String, :length => 50
  property :unit, String, :length => 50
  property :what, String, :length => 50
  property :public, Boolean, :default => true
  property :avgthreshold, Integer, :default => 0
  property :cryptokey, String
  property :adminkey, String
  property :allow_multiple, Boolean, :default => false
  has n, :values
end

class Value
  include DataMapper::Resource
  property :id, Serial
  property :value, Float
  property :valuekey, String
  belongs_to :average
end

set :haml, {:escape_html => true }
Passphrase = "I think Bruce Schneier would cringe."
CONTENT_TYPES = {:html => 'text/html', :css => 'text/css', :js  => 'application/javascript'}

configure :development do
  set :app_url, "http://192.168.0.10:4567/"
end

configure :production do
  set :app_url, 'http://average.heroku.com/'
end
 
before do
  request_uri = case request.env['REQUEST_URI']
    when /\.css$/ : :css
    when /\.js$/  : :js
    else          :html
  end
  content_type CONTENT_TYPES[request_uri], :charset => 'utf-8'
  headers['Cache-Control'] = 'no-cache'
end

helpers do
  include Rack::Utils
  alias_method :h, :escape_html
end

get '/clean/top/:adminkey' do
  adminkey=Rack::Utils.escape(params[:adminkey])
  @avg=Average.first(:adminkey=>adminkey)
  if @avg==nil
    haml "%h1 That average does not exist."
  else
    Value.first(:average_id=>@avg.id,:limit=>1, :order=>[:value.desc]).destroy
    redirect '/avg/'+@avg.cryptokey
  end
end

get '/clean/bottom/:adminkey' do
  adminkey=Rack::Utils.escape(params[:adminkey])
  @avg=Average.first(:adminkey=>adminkey)
  if @avg==nil
    haml "%h1 That average does not exist."
  else
    Value.first(:average_id=>@avg.id,:limit=>1, :order=>[:value.asc]).destroy
    redirect '/avg/'+@avg.cryptokey
  end
end

get '/edit/:adminkey' do
  adminkey=Rack::Utils.escape(params[:adminkey])
  @avg=Average.first(:adminkey=>adminkey)
  if @avg==nil
    haml "%h1 That average does not exist."
  else
    haml :new, :locals => { :edit_or_create => "Edit"}
  end
end

get '/new' do
  @avg=Average.new( :name=> "", :unit => "", :what => "",
                     :public => true, :avgthreshold=> 7,
                     :allow_multiple => false, :adminkey=>"")
  haml :new, :locals => { :edit_or_create => "Create"}
end

post '/new' do
  @public = params[:public] || 'no'
  @public = 'yes' if @public!='no'
  pub = @public=='yes' ? true : false
  @allow_multiple = params[:allow_multiple] || 'no'
  @allow_multiple = 'yes' if @allow_multiple != 'no'
  allow = @allow_multiple=='yes' ? true : false
  threshold = params[:avgthreshold].to_i rescue 0 
  if params[:name].length==0
    throw :halt, [200, "You have to give a name."]
  end
  if params[:adminkey]!="" then
    @avg = Average.first(:adminkey=>params[:adminkey])
    if @avg==nil then
      throw :halt, [200, "That average does not exist. I even suspect that you could be a cheater."]
    else
      @avg.name=params[:name]
      @avg.unit=params[:unit]
      @avg.what=escape_html(params[:what])
      @avg.public=pub
      @avg.avgthreshold=threshold
      @avg.allow_multiple=allow
    end
  else
    @avg = Average.new( :name=> params[:name], :unit => escape_html(params[:unit]), 
                        :what => params[:what], 
                        :public => pub, :avgthreshold=> threshold, 
                        :allow_multiple => allow)
  end
  @avg.save
  if params[:adminkey]=="" then
    blowfish = Crypt::Blowfish.new(Passphrase)
    encryptedBlock = blowfish.encrypt_block(((rand(100)+20).to_s+@avg.id.to_s).ljust(8))
    @avg.cryptokey=Rack::Utils.escape((Base64.encode64(encryptedBlock).strip)).gsub("%2F","_").gsub("%3D","")
    encryptedBlock = blowfish.encrypt_block((@avg.id.to_s+(rand(100)+20).to_s+"!").ljust(8))
    @avg.adminkey=Rack::Utils.escape((Base64.encode64(encryptedBlock).strip)).gsub("%2F","_").gsub("%3D","")
    @avg.save
  end
  haml :show
end

get '/' do 
  @avgs=Average.all(:public => true, :limit => 25, :order => [:id.desc])
  haml :index, :layout => false
end

get '/poll/edit/:valuekey' do
  valuekey=Rack::Utils.escape(params[:valuekey])
  if valuekey==""
    haml "%h1 Hey! Please do not do that."
  else
    if nil == (@value=Value.first(:valuekey=>valuekey))
      haml "%h1 That value does not exist."
    else
      @avg=Average.get(@value.average_id)
      average=@avg.values.avg(:value)
      @value_warning="<strong style='color:red'>Your value is three times "
      if @value.value>average*3 then
        @value_warning+="or more than the average. Please make sure it's correct.<br/></strong>"
      elsif @value.value<average/3 then
        @value_warning+="less than the average. Please make sure it's correct.<br/></strong>"
      else
        @value_warning=""
      end
      haml :edit_value
    end
  end
end

post '/poll/edit/:valuekey' do
  valuekey=Rack::Utils.escape(params[:valuekey])
  if valuekey==""
    haml "%h1 Hey! Please do not do that."
  else
    if nil == (@value=Value.first(:valuekey=>valuekey))
      haml "%h1 That value does not exist."
    else
      @value.value=Float(params[:value]) rescue 0
      @value.save
      @avg=Average.get(@value.average_id)
      response.set_cookie("average"+@avg.cryptokey, {:value=>"valuekey="+@value.valuekey,:path=>"/", :expires => (Time.now+10**7)})
      redirect "/poll/edit/"+valuekey      
    end
  end
end

post '/poll' do
  cid=params[:cryptokey]
  if cid=="" then
    haml "%h1 Hey! Please do not do that."
  else
    @avg=Average.first(:cryptokey=>cid)
    if @avg==nil
      haml "%h1 That average does not exist."
    else
      if @avg.allow_multiple==false then
        cookie=request.cookies["average"+@avg.cryptokey]
      else
        cookie=nil
      end
      if cookie!=nil then
        haml "%h1 You are only supposed to enter one value."
      else
        if (Float(params[:value]) rescue false) then 
          v=Float(params[:value]) rescue 0
          value=@avg.values.new(:value=>v)
          value.save
          blowfish = Crypt::Blowfish.new(Passphrase)
          encryptedBlock = blowfish.encrypt_block((value.id.to_s+@avg.id.to_s+(rand(100)+20).to_s).ljust(8))
          value.valuekey=Rack::Utils.escape((Base64.encode64(encryptedBlock).strip)).gsub("%2F","_").gsub("%3D","")
          value.save
          response.set_cookie("average"+@avg.cryptokey, {:value=>"valuekey="+value.valuekey , :expires => (Time.now+10**7)})
          redirect "/poll/edit/"+value.valuekey
        else
          @val=params[:value]
          haml "%h1== #{@val} is not a number."
        end
      end
    end
  end
end

get '/poll/:cid' do
  cid=Rack::Utils.escape(params[:cid])
  @avg=Average.first(:cryptokey=>cid)
  if @avg==nil
    haml "%h1 That average does not exist."
  else
    if @avg.allow_multiple==false then
      cookie=request.cookies["average"+@avg.cryptokey]
    else
      cookie=nil
    end
    if cookie!=nil then
      redirect '/avg/'+@avg.cryptokey
    else
      haml :poll # , :locals => {:average => @avg.values.avg(:value)}
    end
  end
end

get '/avg/:cid' do
  cid=Rack::Utils.escape(params[:cid])
  @avg=Average.first(:cryptokey=>cid)
  if @avg==nil
    haml "%h1 That average does not exist."
  else
    average=0.0
    sample_size=@avg.values.count
    @already_done=""
#    if @avg.allow_multiple==false then
    cookie=request.cookies["average"+@avg.cryptokey]
    if cookie!=nil then
      if (cookie=~/valuekey=/)!=nil then
        @value=Value.first(:valuekey=>cookie.split("=")[1])
        @already_done="You entered " + sprintf("%.2f",@value.value) + ". "
      else
        @already_done="You've already entered a value in this poll."
      end
    end
#    end
    if sample_size>=@avg.avgthreshold && sample_size>0
      # average=@avg.values.avg(:value)
      values=@avg.values.all.map{|v|v.value}
      mean = values.inject{|acc, n| acc + n} / sample_size.to_f
      stddev = Math.sqrt( values.inject(0) { |sum, e| sum + (e - mean) ** 2 } / sample_size.to_f )
      haml :average, :locals => { :average => sprintf("%.2f",mean), 
                                  :sample_size => sample_size,
                                  :stddev => sprintf("%.2f",stddev),
                                  :cookie=>cookie}
    else
      values_to_collect = @avg.avgthreshold-sample_size
      values_to_collect += 1 if values_to_collect==0
      haml :not_enough_data, :locals => { :values_to_collect => values_to_collect }
    end
  end
end

__END__

@@layout
!!! XML
!!! Basic
%html
  %head
    %title Don't be mean, be average!
    %link{:href=>"/stylesheets/style.css",:media=>"screen",:rel=>"stylesheet",:type=>"text/css"}
    %link{:rel=>"icon", :type=>"image/gif", :href=>"/favicon.ico"}
  %body
    != yield
    #linkhome
      %br
      %br
      %a{:href=>'/'} Home
      %p
        %a{:href=>'mailto:jonas@plea.se', :class=>'contact'}Contact
