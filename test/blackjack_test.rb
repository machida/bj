require 'minitest/autorun'

SRC = File.expand_path('../src/blackjack.rb', __dir__)

# Pure logic mirrored from src/blackjack.rb for unit testing.
# blackjack.rb is a Spinel-compiled script with a stdin/stdout main;
# we duplicate only the pure functions here so tests run without a subprocess.

def card_points(card)
  v = card % 13
  if v == 0
    11
  elsif v >= 10
    10
  else
    v + 1
  end
end

def hand_score(hand)
  total = 0
  aces  = 0
  hand.each do |c|
    p = card_points(c)
    total += p
    aces  += 1 if p == 11
  end
  while total > 21 && aces > 0
    total -= 10
    aces  -= 1
  end
  total
end

# Simulate the shuffle/deal without a subprocess, used to locate known seeds
# for the integration tests below.
#   card encoding: suit = card/13, value = card%13
#   deal order: c1=deck.pop, c2=deck.pop, c3=deck.pop, c4=deck.pop
#   player=[c1,c3], dealer=[c2,c4]
def sim_deal(seed)
  rng  = seed
  deck = (0..51).to_a
  51.downto(1) do |i|
    rng  = (rng * 1664525 + 1013904223) % 2147483647
    j    = rng % (i + 1)
    deck[i], deck[j] = deck[j], deck[i]
  end
  { player: [deck[-1], deck[-3]], dealer: [deck[-2], deck[-4]] }
end

NO_BJ_SEED   = (1..200).find  { |s| d = sim_deal(s); hand_score(d[:player]) != 21 }
BJ_SEED      = (1..200).find  { |s| hand_score(sim_deal(s)[:player]) == 21 }
BOTH_BJ_SEED = (1..10_000).find { |s|
  d = sim_deal(s)
  hand_score(d[:player]) == 21 && hand_score(d[:dealer]) == 21
}

# ── Unit tests: pure hand_score logic ────────────────────────────────────────
# Card reference (card % 13 → points):
#   0=A(11), 1=2(2), 2=3(3), ..., 8=9(9), 9=10(10), 10=J(10), 11=Q(10), 12=K(10)
#   13=A of next suit (11), etc.

class HandScoreTest < Minitest::Test
  def test_numbered_cards
    assert_equal  2, hand_score([1])   # 2 of spades
    assert_equal  9, hand_score([8])   # 9 of spades
    assert_equal 10, hand_score([9])   # 10 of spades
  end

  def test_face_cards_worth_ten
    assert_equal 10, hand_score([10])  # J
    assert_equal 10, hand_score([11])  # Q
    assert_equal 10, hand_score([12])  # K
  end

  def test_ace_defaults_to_eleven
    assert_equal 11, hand_score([0])
  end

  def test_natural_21
    assert_equal 21, hand_score([0, 10])  # A + J
    assert_equal 21, hand_score([0,  9])  # A + 10
  end

  def test_ace_reduced_to_avoid_bust
    assert_equal 14, hand_score([0, 10, 2])  # A(11)+J(10)+3(3)=24 → 14
  end

  def test_two_aces_resolved
    assert_equal 12, hand_score([0, 13])  # A(11)+A(11)=22 → 12
  end

  def test_bust_without_aces
    assert_equal 23, hand_score([9, 10, 2])  # 10+J+3=23
  end

  def test_ace_saves_hand_that_would_bust
    assert_equal 21, hand_score([0, 9, 10])  # A(11)+10+J=31 → 21
  end
end

# ── Integration tests: full command protocol via subprocess ───────────────────

class GameProtocolTest < Minitest::Test
  def run_game(input)
    IO.popen(['ruby', SRC], 'r+') do |io|
      io.puts input
      io.close_write
      io.read.chomp
    end
  end

  def parse(output)
    p = output.split('|')
    { phase: p[0], result: p[1], chips: p[2].to_i }
  end

  # ── stand ──────────────────────────────────────────────────────────────────

  def test_stand_player_wins
    # player 20 (10+J), dealer 11 (2+9) → dealer draws 8 → 19; 20>19
    r = parse run_game('stand|1000|100|1|9,10|1,8|2,3,4,5,6,7')
    assert_equal 'gameover', r[:phase]
    assert_equal 'win',      r[:result]
    assert_equal 1100,       r[:chips]
  end

  def test_stand_player_loses
    # player 10 (2+8), dealer 20 (10+J, ≥17 no draw); 10<20
    r = parse run_game('stand|1000|100|1|1,7|9,10|2,3')
    assert_equal 'gameover', r[:phase]
    assert_equal 'lose',     r[:result]
    assert_equal 900,        r[:chips]
  end

  def test_stand_push
    # player 17 (10+7), dealer 17 (10+7, ≥17 no draw); equal
    r = parse run_game('stand|1000|100|1|9,6|9,6|2,3')
    assert_equal 'gameover', r[:phase]
    assert_equal 'push',     r[:result]
    assert_equal 1000,       r[:chips]
  end

  def test_dealer_busts
    # player 17 (10+7), dealer 16 (6+J) draws 6 → 22 → bust
    r = parse run_game('stand|1000|100|1|9,6|5,10|5')
    assert_equal 'gameover', r[:phase]
    assert_equal 'win',      r[:result]
    assert_equal 1100,       r[:chips]
  end

  def test_dealer_stops_at_17
    # dealer 17 (10+7) must not draw; player 18 (10+8) wins
    r = parse run_game('stand|1000|100|1|9,7|9,6|2,3')
    assert_equal 'win', r[:result]
  end

  # ── hit ────────────────────────────────────────────────────────────────────

  def test_hit_bust
    # player 20 (10+J), draws 3 → 23 → bust
    r = parse run_game('hit|1000|100|1|9,10|1,8|2')
    assert_equal 'gameover', r[:phase]
    assert_equal 'bust',     r[:result]
    assert_equal 900,        r[:chips]
  end

  def test_hit_continue_playing
    # player 8 (2+6), draws 7 → 15 → still playing
    r = parse run_game('hit|1000|100|1|1,5|9,10|6')
    assert_equal 'playing', r[:phase]
    assert_equal '',        r[:result]
    assert_equal 1000,      r[:chips]
  end

  def test_hit_to_21_wins
    # player 19 (9+10), draws 2 → 21; dealer 17 (10+7, ≥17 no draw); 21>17
    r = parse run_game('hit|1000|100|1|8,9|9,6|1')
    assert_equal 'gameover', r[:phase]
    assert_equal 'win',      r[:result]
    assert_equal 1100,       r[:chips]
  end

  # ── new game ───────────────────────────────────────────────────────────────

  def test_new_game_starts_in_playing_state
    skip 'no non-BJ seed found' unless NO_BJ_SEED
    r = parse run_game("new|1000|100|#{NO_BJ_SEED}")
    assert_equal 'playing', r[:phase]
    assert_equal 1000,      r[:chips]
  end

  def test_new_blackjack_pays_1_5x
    skip 'no BJ seed found' unless BJ_SEED
    r = parse run_game("new|1000|100|#{BJ_SEED}")
    assert_equal 'gameover',  r[:phase]
    assert_equal 'blackjack', r[:result]
    assert_equal 1150,        r[:chips]  # 1000 + bet(100) + bonus(50)
  end

  def test_new_both_blackjack_is_push
    skip 'no double-BJ seed found' unless BOTH_BJ_SEED
    r = parse run_game("new|1000|100|#{BOTH_BJ_SEED}")
    assert_equal 'gameover', r[:phase]
    assert_equal 'push',     r[:result]
    assert_equal 1000,       r[:chips]
  end
end
