package emu

import "core:fmt"
import sdl "vendor:sdl3"

@(private="file")
UI_COUNT :: 200
UI_SPRITE_COUNT :: 4
@(private="file")
UI_FONT_RATIO :: 18.0 / 14.0

Ui_Anchor :: enum {
    top_left,
    top_center,
    top_right,
    middle_left,
    middle_center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
}

Ui_element :: struct {
    size: Vector2f,
    position: Vector2f,
    color: Vector4f,
    sprite: Sprite2,
    anchor: Ui_Anchor,
    text: string,
    disabled: bool,
    parent: ^Ui_element,

    _input: ^Ui_element,
    _prev_hover: bool,
    _position: Vector2f,
    _disabled: bool,

    on_mouse_enter: proc(element: ^Ui_element),
    on_mouse_leave: proc(element: ^Ui_element),
    on_mouse_move: proc(element: ^Ui_element, position: Vector2f),
    on_mouse_down: proc(element: ^Ui_element, button: map[Mouse_button]bool),
    on_mouse_up: proc(element: ^Ui_element, button: map[Mouse_button]bool),
    on_mouse_click: proc(element: ^Ui_element),
}

Sprite2 :: struct {
    texture: u32,
    width: int,
    height: int,
    frames: Vector2f,
    offset: Vector2f,
    color: Vector4f,
}

@(private="file")
ui: [UI_COUNT]Ui_element
@(private="file")
ui_occupied: [UI_COUNT]bool
ui_sprites: [UI_SPRITE_COUNT]Sprite2
@(private="file")
ui_index: i32
mouse_state: Mouse_state
@(private="file")
ui_buttons: [20]^Ui_element
@(private="file")
prev_click: ^Ui_element
@(private="file")
button_index := 0
@(private="file")
last_index := -1
@(private="file")
ui_button_id := 0
VIRTUAL_HEIGHT :: 144
ui_process :: proc() {
    blocking: bool

    mouse_down: map[Mouse_button]bool
    mouse_up: map[Mouse_button]bool

    for i in Mouse_button {
        if mouse_pressed_raw(i) {
            mouse_down[i] = true
        }
        if mouse_released_raw(i) {
            mouse_up[i] = true
        }
    }

    for &e, i in ui {
        if ui_occupied[i] {
            //TODO: Hack? Text gets click event sometimes so for now just disable events on text objects.
            ui_calc_parent(&e)
            if e._disabled || e.text != "" {
                continue
            }
            hover := false
            pos := (e._position - (resolution / 2)) * -1
            if  mouse_state.position.x > pos.x &&
                mouse_state.position.x < pos.x + e.size.x &&
                mouse_state.position.y > pos.y &&
                mouse_state.position.y < pos.y + e.size.y {
                    hover = true
                    blocking = true
            }
            set_blocking(blocking)
            if hover && !e._prev_hover {
                if e.on_mouse_enter != nil {
                    button := ui_buttons[button_index]
                    if button != nil && button.on_mouse_leave != nil {
                        button.on_mouse_leave(button)
                    }
                    e.on_mouse_enter(&e)
                }
            }
            if !hover && e._prev_hover {
                if e.on_mouse_leave != nil {
                    e.on_mouse_leave(&e)
                }
            }
            if hover && e._prev_hover {
                if mouse_down != nil {
                    if e.on_mouse_down != nil {
                        e.on_mouse_down(&e, mouse_down)
                    }
                    prev_click = &e
                }
                if mouse_up != nil {
                    if e.on_mouse_up != nil {
                        e.on_mouse_up(&e, mouse_up)
                    }
                    if prev_click == &e {
                        if e.on_mouse_click != nil {
                            e.on_mouse_click(&e)
                        }
                    }
                }
            }
            if e.on_mouse_move != nil {
                e.on_mouse_move(&e, mouse_state.position)
            }
            e._prev_hover = hover
        }
    }
    if mouse_up != nil {
        prev_click = nil
    }
    if !blocking {
        if mouse_pressed(.left) {
            text_input_stop()
        }
    }
}

@(private="file")
ui_calc_parent :: proc(e: ^Ui_element) {
    e._disabled = (e.parent != nil && e.parent.disabled) || e.disabled
}

ui_clear :: proc() {
    ui = {}
    ui_occupied = {}
    ui_buttons = {}
    button_index = 0
    ui_button_id = 0
    last_index = -1
    ui_index = 0
}

sprite_create :: proc(data: []u8, frames: Vector2f) -> Sprite2 {
    texture, w, h := texture_from_sprite(data)
    return Sprite2{texture, w, h, frames, {0, 0}, {1, 1, 1, 1}}
}

sprite_destroy :: proc(sprite: ^Sprite2) {
    texture_destroy(sprite.texture)
}

IMG_UI_0 :: "sprites/White.png"
IMG_UI_1 :: "sprites/Bitmap_font.png"
IMG_UI_2 :: "sprites/Pause.png"
IMG_UI_3 :: "sprites/Button.png"

ui_sprite_create_all :: proc() {
    ui_sprites[0] = sprite_create(#load(IMG_UI_0), {1, 1})
    ui_sprites[1] = sprite_create(#load(IMG_UI_1), {18, 6})
    ui_sprites[2] = sprite_create(#load(IMG_UI_2), {1, 1})
    ui_sprites[3] = sprite_create(#load(IMG_UI_3), {1, 1})
 }

ui_sprite_destroy_all :: proc() {
    for i in 0..<UI_SPRITE_COUNT {
        sprite_destroy(&ui_sprites[i])
    }
}

ui_image :: proc(position: Vector2f, size: Vector2f, sprite: int,
        anchor: Ui_Anchor, parent: ^Ui_element = nil) -> ^Ui_element {
    element := &ui[ui_index]
    ui_occupied[ui_index] = true
    ui_index += 1
    element.size = size
    element.position = position
    element.color = {1, 1, 1, 1}
    element.sprite = ui_sprites[sprite]
    element.anchor = anchor
    element.parent = parent
    return element
}

ui_container :: proc(position: Vector2f, anchor: Ui_Anchor, 
        parent: ^Ui_element = nil) -> ^Ui_element {
    element := ui_image(position, {0, 0}, 0, anchor, parent)
    return element
}

ui_text :: proc(position: Vector2f, size: f32, text: string, 
        anchor: Ui_Anchor, parent: ^Ui_element = nil) -> ^Ui_element {
    element := ui_image(position, {size, UI_FONT_RATIO * size}, 1, anchor, parent)
    element.color = {0, 0, 0, 1}
    element.text = text
    return element
}

ui_button :: proc(position: Vector2f, size: Vector2f, on_click: proc(element: ^Ui_element),
        anchor: Ui_Anchor, parent: ^Ui_element = nil) -> ^Ui_element {
    element := ui_image(position, size, 3, anchor)
    element.on_mouse_click = on_click
    element.parent = parent
    ui_buttons[ui_button_id] = element
    ui_button_id += 1
    return element
}

ui_input :: proc(position: Vector2f, size: Vector2f, anchor: Ui_Anchor, 
        parent: ^Ui_element = nil) -> ^Ui_element {
    element := ui_image(position, size, 0, anchor)
    element._input = ui_text({2, 0}, size.y - 10, "", .middle_left, element)
    element.parent = parent
    element.on_mouse_click = text_input_click
    ui_buttons[ui_button_id] = element
    ui_button_id += 1
    return element
}

ui_render :: proc() {
    old_cam := render_get_camera()
    for &e, i in ui {
        if ui_occupied[i] {
            if (e.parent != nil && e.parent._disabled) || e.disabled {
                continue
            }
            pos: Vector2f
            if e.parent != nil {
                pos = e.parent._position
            } else {
                pos = ui_get_render_pos(e.anchor)
            }
            render_set_camera(pos.x, pos.y)
            e._position = pos

            eposition := e.position
            switch e.anchor {
            case .top_left:
                eposition.y -= e.size.y
                if e.parent != nil {
                    eposition.y += e.parent.size.y
                }
            case .top_center:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e) / 2
                } else {
                    eposition.x -= e.size.x / 2
                }
                eposition.y -= e.size.y
                if e.parent != nil {
                    eposition.x += e.parent.size.x / 2
                    eposition.y += e.parent.size.y
                }
            case .top_right:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e)
                } else {
                    eposition.x -= e.size.x
                }
                eposition.y -= e.size.y
                if e.parent != nil {
                    eposition.x += e.parent.size.x
                    eposition.y += e.parent.size.y
                }
            case .middle_left:
                eposition.y -= e.size.y / 2
                if e.parent != nil {
                    eposition.y += e.parent.size.y / 2
                }
            case .middle_center:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e) / 2
                } else {
                    eposition.x -= e.size.x / 2
                }
                eposition.y -= e.size.y / 2
                if e.parent != nil {
                    eposition.x += e.parent.size.x / 2
                    eposition.y += e.parent.size.y / 2
                }
            case .middle_right:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e)
                } else {
                    eposition.x -= e.size.x
                }
                eposition.y -= e.size.y / 2
                if e.parent != nil {
                    eposition.x += e.parent.size.x
                    eposition.y += e.parent.size.y / 2
                }
            case .bottom_left:
                //Do nothing
            case .bottom_center:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e) / 2
                } else {
                    eposition.x -= e.size.x / 2
                }
                if e.parent != nil {
                    eposition.x += e.parent.size.x / 2
                }
            case .bottom_right:
                if e.text != "" {
                    eposition.x -= ui_get_text_width(&e)
                } else {
                    eposition.x -= e.size.x
                }
                if e.parent != nil {
                    eposition.x += e.parent.size.x
                }
            }
            e._position -= eposition
            if e.size.x == 0 {
                continue
            }

            if e.text == "" {
                offset_y := ((e.sprite.frames.y - e.sprite.offset.y) / e.sprite.frames.y)
                offset :Vector2f= {e.sprite.offset.x / e.sprite.frames.x, 1 - offset_y}
                render_quad({
                    texture = e.sprite.texture,
                    position = eposition,
                    size = e.size,
                    scale = 1 / e.sprite.frames,
                    offset = offset,
                    flip = {0, 0},
                    color = e.color,
                })
            } else {
                render_text(e.sprite, e.text, eposition, e.size, e.color)
            }
        }
    }
    render_set_camera(old_cam.x, old_cam.y)
}

@(private="file")
ui_get_render_pos :: proc(anchor: Ui_Anchor) -> Vector2f {
    half_res := resolution / 2

    switch anchor {
    case .top_left:
        return {half_res.x, -half_res.y}
    case .top_center:
        return {0, -half_res.y}
    case .top_right:
        return {-half_res.x, -half_res.y}
    case .middle_left:
        return {half_res.x, 0}
    case .middle_center:
        return {0, 0}
    case .middle_right:
        return {-half_res.x, 0}
    case .bottom_left:
        return {half_res.x, half_res.y}
    case .bottom_center:
        return {0, half_res.y}
    case .bottom_right:
        return {-half_res.x, half_res.y}
    }
    return {0, 0}
}

ui_get_text_width :: proc(text: ^Ui_element) -> f32 {
    return f32(len(text.text)) * text.size.x
}