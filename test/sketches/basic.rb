# frozen_string_literal: true

def setup
  frame_rate(10)
end

def draw
  background 0
  if frame_count == 3
    puts 'ok'
    exit
  end
end

def settings
  size(300, 300)
end
