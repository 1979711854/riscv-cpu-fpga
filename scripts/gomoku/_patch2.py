# -*- coding: utf-8 -*-
"""一次性补丁：落子后临时隐藏光标。用完即删。"""
import io

Q1 = chr(0x300C)   # 「
Q2 = chr(0x300D)   # 」

# ---- game.h ----
p = 'game.h'
s = io.open(p, encoding='utf-8').read()

old = "    int cursor_on;              /* 闪烁：这一拍光标画不画 */"
new = ("    int cursor_on;              /* 闪烁：这一拍光标画不画 */\n"
       "    int cursor_hidden;          /* 落子后临时藏起光标 —— 见 game_cursor_shown 的说明 */")
assert old in s, 'h1'
s = s.replace(old, new)

old = "/* 光标是否要画出来（闪烁 + 非 AI 思考时）*/"
new = ("/* 光标是否要画出来。\n"
       " * [!] 落子之后会【临时藏起来】，直到玩家再按方向键。原因：显示层没有精灵，\n"
       " *     光标和棋子占用的是【同一层的同一块图块】—— 光标画着就看不见底下的子。\n"
       " *     而刚落完子那一拍恰恰是玩家最想确认自己下在哪的时候，所以让它先消失，\n"
       " *     一按键（反正要挪光标了）立刻回来。\n"
       " *     另一条路是给 9 种网格形状各加 黑/白 两个带光标的图块（+18 块 = +4.6KB），\n"
       " *     但 32KB 里那 4.6KB 更该留给后面加字库。 */")
assert old in s, 'h2'
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)
print('game.h ok')

# ---- game.c ----
p = 'game.c'
s = io.open(p, encoding='utf-8').read()

old = "    gm->cursor_on    = 1;\n    gm->t_blink      = 0;"
new = "    gm->cursor_on    = 1;\n    gm->cursor_hidden= 0;\n    gm->t_blink      = 0;"
assert old in s, 'c1'
s = s.replace(old, new)

old = "return (gm->phase == GAME_PLAYING && gm->cursor_on) ? 1 : 0;"
new = "return (gm->phase == GAME_PLAYING && gm->cursor_on && !gm->cursor_hidden) ? 1 : 0;"
assert old in s, 'c2'
s = s.replace(old, new)

old = ('            gm->cursor_on = 1;              /* 一移动就把光标点亮，别让它正好落在暗的半拍 */\n'
       '            gm->t_blink   = now;            /* 闪烁计时从' + Q1 + '这次移动' + Q2 + '重新起算 */')
new = ('            gm->cursor_on     = 1;          /* 一移动就把光标点亮，别让它正好落在暗的半拍 */\n'
       '            gm->cursor_hidden = 0;          /* 同时解除"落子后藏起来" */\n'
       '            gm->t_blink       = now;        /* 闪烁计时从这次移动重新起算 */')
assert old in s, 'c3'
s = s.replace(old, new)

old = "            if (ret == GOMOKU_OK) {\n                after_move(gm);"
new = ("            if (ret == GOMOKU_OK) {\n"
       "                /* 落子成功 -> 先把光标藏起来，让玩家看清自己刚下的那一手。\n"
       "                 * 理由见 game.h 的 game_cursor_shown 注释。 */\n"
       "                gm->cursor_hidden = 1;\n"
       "                after_move(gm);")
assert old in s, 'c4'
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)
print('game.c ok')
