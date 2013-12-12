#!/usr/bin/env ruby

require 'trollop'
require 'tempfile'
require 'open3'


# execute
SMT_SEMPARSE = '/workspace/grounded/mosesdecoder/moses-chart-cmd/bin/gcc-4.7/release/debug-symbols-on/link-static/threading-multi/moses_chart -f /workspace/grounded/smt-semparse/latest/model/moses.ini 2>/dev/null'
EVAL_PL = '/workspace/grounded/wasp-1.0/data/geo-funql/eval/eval.pl'
def exec natural_language_string, reference_output
  flat_mrl = `echo "#{natural_language_string}" | ./stem.py | #{SMT_SEMPARSE}`.strip
  func = `echo "#{flat_mrl}" | ./functionalize.py 2>/dev/null`.strip
  res = `echo "execute_funql_query(#{func}, X)." | swipl -s #{EVAL_PL} 2>&1  | grep "X ="`.strip.split('X = ')[1]
  puts "     nrl: #{natural_language_string}"
  puts "flat mrl: #{flat_mrl}"
  puts "    func: #{func}"
  puts "  output: #{res}"
  return res==reference_output, func, res
end


# decoder interaction/translations
class Translation
  attr_accessor :s, :f, :rank, :model, :score

  def initialize kbest_line, rank=-1
    a = kbest_line.split ' ||| '
    @s = a[1].strip
    h = {}
    a[2].split.each { |i|
      name, value = i.split '='
      value = value.to_f
      h[name] = value
    }
    @f = NamedSparseVector.new h
    @rank = rank
    @model = a[3].to_f
    @score = -1.0
  end

  def to_s
    "#{@rank} ||| #{@s} ||| #{@model} ||| #{@score} ||| #{@f.to_s}"
  end
end

CDEC = "/toolbox/cdec-dtrain/bin/cdec -r"
def predict_translation s, k, ini, w
  cmd = " echo \"#{s}\" | #{CDEC} -c #{ini} -k #{k} -w #{w} 2>/dev/null"
  o, s = Open3.capture2(cmd)
  j = -1
  return o.split("\n").map{|i| j+=1; Translation.new(i, j)}
end


# scoring (per-sentence BLEU)
def ngrams_it(s, n, fix=false)
  a = s.strip.split
  a.each_with_index { |tok, i|
    tok.strip!
    0.upto([n-1, a.size-i-1].min) { |m|
      yield a[i..i+m] if !(fix||(a[i..i+m].size>n))
    }
  }
end

def brevity_penalty h, r
  a = h.split
  b = r.split
  return 1.0 if a.size>b.size
  return Math.exp(1.0 - b.size.to_f/a.size);
end

def per_sentence_bleu h, r, n=4
  h_ng = {}
  r_ng = {}
  (1).upto(n) { |i| h_ng[i] = []; r_ng[i] = [] }
  ngrams_it(h, n) { |i| h_ng[i.size] << i }
  ngrams_it(r, n) { |i| r_ng[i.size] << i }
  m = [n,r.split.size].min
  weight = 1.0/m
  add = 0.0
  sum = 0
  (1).upto(m) { |i|
    counts_clipped = 0
    counts_sum = h_ng[i].size
    h_ng[i].uniq.each { |j| counts_clipped += r_ng[i].count(j) }
    add = 1.0 if i >= 2
    sum += weight * Math.log((counts_clipped + add)/(counts_sum + add));
  }
  return brevity_penalty(h,r) * Math.exp(sum)
end

def score_translations a, reference
  a.each_with_index { |i,j|
    i.score = per_sentence_bleu i.s, reference
  }
end
### /scoring



### hope and fear
def hope_and_fear a, act='hope'
  max = -1.0/0
  max_idx = -1
  a.each_with_index { |i,j|
  if act=='hope' && i.model + i.score > max
    max_idx = j; max = i.model + i.score
  end
  if act=='fear' && i.model - i.score > max
    max_idx = j; max = i.model - i.score
  end
  }
  return a[max_idx]
end
### /hope and fear



### update
def update w, hope, fear
  w = w + (hope.f - fear.f)
  return w
end
### /update



### weights
class NamedSparseVector
  attr_accessor :h

  def initialize init=nil
    @h = {}
    @h = init if init
    @h.default = 0.0
  end

  def + other
    new_h = Hash.new
    new_h.update @h
    ret = NamedSparseVector.new new_h
    other.each_pair { |k,v| ret[k]+=v }
    return ret
  end

  def from_file fn
    f = File.new(fn, 'r')
    while line = f.gets
      name, value = line.strip.split
      value = value.to_f
      @h[name] = value
    end
  end

  def to_file
    s = []
    @h.each_pair { |k,v| s << "#{k} #{v}" }
    s.join("\n")+"\n"
  end

  def - other
    new_h = Hash.new
    new_h.update @h
    ret = NamedSparseVector.new new_h
    other.each_pair { |k,v| ret[k]-=v }
    return ret
  end

  def * scalar
    raise ArgumentError, "Arg is not numeric #{scalar}" unless scalar.is_a? Numeric
    ret = NamedSparseVector.new
    @h.keys.each { |k| ret[k] = @h[k]*scalar }
    return ret
  end

  def dot other
    sum = 0.0
    @h.each_pair { |k,v|
      sum += v * other[k]
    }
    return sum
  end

  def [] k
    @h[k]
  end

  def []= k, v
    @h[k] = v
  end

  def each_pair
    @h.each_pair { |k,v| yield k,v }
  end

  def to_s
    @h.to_s
  end

  def size
    @h.keys.size
  end
end
### /weights


def test opts
  w = NamedSparseVector.new
  w.from_file opts[:init_weights]
  input = File.new(opts[:input], 'r').readlines.map{|i|i.strip}
  references = File.new(opts[:references], 'r').readlines.map{|i|i.strip}
  f = File.new('weights.tmp', 'w+')
  f.write w.to_file
  f.close
  kbest = predict_translation input[0], opts[:k], 'weights.tmp'
  score_translations kbest, references[0]
  kbest.each_with_index { |i,j|
    puts "#{i.rank} #{i.s} #{i.model} #{i.score}"
  }
  puts
  puts "hope"
  hope = hope_and_fear kbest, 'hope'
  puts "#{hope.rank} #{hope.s} #{hope.model} #{hope.score}"
  puts "fear"
  fear = hope_and_fear kbest, 'fear'
  puts "#{fear.rank} #{fear.s} #{fear.model} #{fear.score}"
end

def adj_model a
  min = a.map{|i|i.model}.min
  max = a.map{|i|i.model}.max
  a.each { |i|
    i.model = (i.model-min)/(max-min)
  }
end

def main
  opts = Trollop::options do
    opt :k, "k", :type => :int, :required => true
    opt :input, "'foreign' input", :type => :string, :required => true
    opt :references, "(parseable) references", :type => :string, :required => true
    opt :gold, "gold standard parser output", :type => :string, :require => true
    opt :gold_mrl, "gold standard mrl", :type => :string, :short => '-h', :require => true
    opt :init_weights, "initial weights", :type => :string, :required => true, :short => '-w'
    opt :cdec_ini, "cdec config file", :type => :string, :default => './cdec.ini'
  end

  input = File.new(opts[:input], 'r').readlines.map{|i|i.strip}
  references = File.new(opts[:references], 'r').readlines.map{|i|i.strip}
  gold = File.new(opts[:gold], 'r').readlines.map{|i|i.strip}
  gold_mrl = File.new(opts[:gold_mrl], 'r').readlines.map{|i|i.strip}

  # init weights
  w = NamedSparseVector.new
  w.from_file opts[:init_weights]


  positive_feedback = 0
  without_translations = 0
  with_proper_parse = 0
  with_output = 0
  count = 0
  input.each_with_index { |i,j|
    count += 1
    # write current weights to file
    tmp_file = Tempfile.new('rampion')
    tmp_file_path = tmp_file.path
    tmp_file.write w.to_file
    tmp_file.close
    # get kbest list for current input
    kbest = predict_translation i, opts[:k], opts[:cdec_ini], tmp_file_path
    if kbest.size==0 # FIXME: shouldnt happen
      without_translations += 1
      next
    end
    score_translations kbest, references[j]
    adj_model kbest
    # get feedback
 
    puts "----top1"
    puts "0 #{kbest[0].s} #{kbest[0].model} #{kbest[0].score}"
    feedback, func, output = exec kbest[0].s, gold[j]
    with_proper_parse +=1 if func!="None"
    with_output +=1 if output!="null"
    positive_feedback  += 1 if feedback==true
    hope = ''; fear = ''
    if feedback==true
      puts "'#{kbest[0].s}'"
      references[j] = kbest[0].s
      hope = kbest[0]
    else
      hope = hope_and_fear kbest, 'hope'
    end
    fear = hope_and_fear kbest, 'fear'
    
    puts "----hope"
    puts "#{hope.rank} #{hope.s} #{hope.model} #{hope.score}"
    exec hope.s, gold[j]

    puts "----fear"
    puts "#{fear.rank} #{fear.s} #{fear.model} #{fear.score}"
    exec fear.s, gold[j]

    puts "----reference"
    puts "// #{references[j]} // 1.0"
    exec references[j], gold[j]
    puts "GOLD MRL: #{gold_mrl[j]}"
    puts "GOLD OUTPUT #{gold[j]}"

    puts

    w = update w, hope, fear
  }
  puts "#{count} examples"
  puts "#{((positive_feedback.to_f/count)*100).round 2}% with positive feedback (abs: #{positive_feedback})"
  puts "#{((with_proper_parse.to_f/count)*100).round 2}% with proper parse (abs: #{with_proper_parse})"
  puts "#{((with_output.to_f/count)*100).round 2}% with output (abs: #{with_output})"
  puts "#{((without_translations.to_f/count)*100).round 2}% without translations (abs: #{without_translations})"
end


main

