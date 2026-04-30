# Blackjack game for Spinel AOT compiler + WASM
# Protocol (stdin): command|chips|bet|seed|player_cards|dealer_cards|deck
# Protocol (stdout): phase|result|chips|bet|message|player_cards|dealer_cards|deck
# Cards encoded as 0-51: suit=card/13 (S/H/D/C), value=card%13 (A/2/../K)

SUIT_CHARS = ["S", "H", "D", "C"]
VAL_STRS   = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]

$rng = 1

def rng_next(max)
  $rng = ($rng * 1664525 + 1013904223) % 2147483647
  $rng % max
end

def card_str(card)
  VAL_STRS[card % 13] + SUIT_CHARS[card / 13]
end

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
  i = 0
  while i < hand.length
    p = card_points(hand[i])
    if p == 11
      aces += 1
    end
    total += p
    i += 1
  end
  while total > 21 && aces > 0
    total -= 10
    aces  -= 1
  end
  total
end

def encode_cards(cards)
  result = ""
  i = 0
  while i < cards.length
    if i > 0
      result = result + ","
    end
    result = result + cards[i].to_s
    i += 1
  end
  result
end

def decode_cards(str)
  cards = []
  if str.length == 0
    return cards
  end
  parts = str.split(",")
  i = 0
  while i < parts.length
    if parts[i].length > 0
      cards << Integer(parts[i])
    end
    i += 1
  end
  cards
end

def do_shuffle(deck)
  n = deck.length
  i = n - 1
  while i > 0
    j = rng_next(i + 1)
    tmp     = deck[i]
    deck[i] = deck[j]
    deck[j] = tmp
    i -= 1
  end
end

def fresh_deck
  deck = []
  i = 0
  while i < 52
    deck << i
    i += 1
  end
  deck
end

def dealer_draw(dealer_hand, deck)
  while hand_score(dealer_hand) < 17
    dealer_hand << deck.pop
  end
end

# --- read input ---
line = gets.chomp
parts = line.split("|")

cmd   = parts[0]
chips = 1000
bet   = 100
seed  = 1

if parts.length > 1 && parts[1].length > 0
  chips = Integer(parts[1])
end
if parts.length > 2 && parts[2].length > 0
  bet = Integer(parts[2])
end
if parts.length > 3 && parts[3].length > 0
  seed = Integer(parts[3])
end
$rng = seed

player_hand = []
dealer_hand = []
deck        = []

if parts.length > 4 && parts[4].length > 0
  player_hand = decode_cards(parts[4])
end
if parts.length > 5 && parts[5].length > 0
  dealer_hand = decode_cards(parts[5])
end
if parts.length > 6 && parts[6].length > 0
  deck = decode_cards(parts[6])
end

phase   = "playing"
result  = ""
message = ""

if cmd == "new"
  deck = fresh_deck
  do_shuffle(deck)

  c1 = deck.pop
  c2 = deck.pop
  c3 = deck.pop
  c4 = deck.pop
  player_hand = []
  player_hand << c1
  player_hand << c3
  dealer_hand = []
  dealer_hand << c2
  dealer_hand << c4

  ps = hand_score(player_hand)
  ds = hand_score(dealer_hand)

  if ps == 21 && ds == 21
    phase   = "gameover"
    result  = "push"
    message = "Both Blackjack - Push!"
  elsif ps == 21
    phase   = "gameover"
    result  = "blackjack"
    chips   = chips + bet + (bet / 2)
    message = "Blackjack! You win 1.5x!"
  else
    phase   = "playing"
    message = "Hit or Stand?"
  end

elsif cmd == "hit"
  player_hand << deck.pop
  ps = hand_score(player_hand)

  if ps > 21
    phase   = "gameover"
    result  = "bust"
    chips   = chips - bet
    message = "Bust! You lose."
  elsif ps == 21
    dealer_draw(dealer_hand, deck)
    ds = hand_score(dealer_hand)
    if ds > 21 || ps > ds
      chips   = chips + bet
      result  = "win"
      message = "You win with 21!"
    elsif ps == ds
      result  = "push"
      message = "Push!"
    else
      chips   = chips - bet
      result  = "lose"
      message = "Dealer wins."
    end
    phase = "gameover"
  else
    phase   = "playing"
    message = "Hit or Stand?"
  end

elsif cmd == "stand"
  ps = hand_score(player_hand)
  dealer_draw(dealer_hand, deck)
  ds = hand_score(dealer_hand)
  if ds > 21 || ps > ds
    chips   = chips + bet
    result  = "win"
    message = "You win!"
  elsif ps == ds
    result  = "push"
    message = "Push!"
  else
    chips   = chips - bet
    result  = "lose"
    message = "Dealer wins."
  end
  phase = "gameover"

else
  phase   = "error"
  message = "Unknown command"
end

puts phase + "|" + result + "|" + chips.to_s + "|" + bet.to_s + "|" + message + "|" + encode_cards(player_hand) + "|" + encode_cards(dealer_hand) + "|" + encode_cards(deck)
