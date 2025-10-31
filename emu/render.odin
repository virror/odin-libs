package emu

import sdl "vendor:sdl3"
import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "core:log"
import "core:mem"
import "core:fmt"
import "core:image/png"
import libimage "core:image"

Vector2f :: distinct [2]f32
Vector3f :: distinct [3]f32
Vector4f :: distinct [4]f32

Vertex_Data :: struct {
    pos: Vector2f,
    tex: Vector2f,
}

Ui_frag_uniform :: struct {
    coordScale: Vector2f,
    coordOffset: Vector2f,
    color: Vector4f,
}

Ui_vert_uniform :: struct #packed {
    model: matrix[4, 4]f32,
    resolution: Vector2f,
    cameraPos: Vector2f,
    flip: Vector2f,
}

Render_data :: struct {
    texture: u32,
    position: Vector2f,
    size: Vector2f,
    scale: Vector2f,
    offset: Vector2f,
    flip: Vector2f,
    color: Vector4f,
}

resolution: Vector2f
@(private="file")
gpu: ^sdl.GPUDevice
@(private="file")
win: ^sdl.Window
@(private="file")
pipeline_game: ^sdl.GPUGraphicsPipeline
@(private="file")
vertex_buf: ^sdl.GPUBuffer
@(private="file")
index_buf: ^sdl.GPUBuffer
@(private="file")
textures: [UI_SPRITE_COUNT + 3]sdl.GPUTextureSamplerBinding
@(private="file")
texture_id: u32
@(private="file")
cmd_buf: ^sdl.GPUCommandBuffer
@(private="file")
render_pass: ^sdl.GPURenderPass
@(private="file")
camera_position: Vector2f

default_context: runtime.Context

render_init :: proc(window: ^sdl.Window) {
    context.logger = log.create_console_logger()
    default_context = context

    sdl.SetLogPriorities(.VERBOSE)
    sdl.SetLogOutputFunction(proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
        context = default_context
        log.debugf("SDL {} [{}] {}", category, priority, message)
    }, nil)

    gpu = sdl.CreateGPUDevice({.SPIRV, .METALLIB}, false, nil)
    if !sdl.ClaimWindowForGPUDevice(gpu, window) {
        panic("GPU failed to claim window")
    }
    win = window

    create_quad()

    when ODIN_OS == .Darwin {
        vert_shader := shader_create(#load("shaders/shader_vert.metal"), .VERTEX, 1, 0, {.MSL}, "main0")
        frag_shader := shader_create(#load("shaders/shader_frag.metal"), .FRAGMENT, 2, 1, {.MSL}, "main0")
        pipeline_game = pipeline_create(vert_shader, frag_shader)
    } else {
        vert_shader := shader_create(#load("shaders/shader.spv.vert"), .VERTEX, 1, 0, {.SPIRV})
        frag_shader := shader_create(#load("shaders/shader.spv.frag"), .FRAGMENT, 1, 1, {.SPIRV})
        pipeline_game = pipeline_create(vert_shader, frag_shader)
    }
    render_set_shader()
}

@(private="file")
pipeline_create :: proc(vert_shader: ^sdl.GPUShader, frag_shader: ^sdl.GPUShader, ) -> ^sdl.GPUGraphicsPipeline {
    vert_attrs := []sdl.GPUVertexAttribute {
        {
            location = 0,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = u32(offset_of(Vertex_Data, pos)),
        },
        {
            location = 1,
            buffer_slot = 0,
            format = .FLOAT2,
            offset = u32(offset_of(Vertex_Data, tex)),
        },
    }

    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
        vertex_input_state = {
            num_vertex_buffers = 1,
            vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
                slot = 0,
                pitch = size_of(Vertex_Data),
            }),
            num_vertex_attributes = u32(len(vert_attrs)),
            vertex_attributes = raw_data(vert_attrs),
        },
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &(sdl.GPUColorTargetDescription {
                format = sdl.GetGPUSwapchainTextureFormat(gpu, win),
                blend_state = {
                    src_color_blendfactor = .SRC_ALPHA,
                    dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
                    color_blend_op = .ADD,
                    src_alpha_blendfactor = .ONE,
                    dst_alpha_blendfactor = .ZERO,
                    alpha_blend_op = .ADD,
                    enable_blend = true,
                },
            }),
        },
    })
    sdl.ReleaseGPUShader(gpu, vert_shader)
    sdl.ReleaseGPUShader(gpu, frag_shader)
    return pipeline
}

render_deinit :: proc() {
    sdl.ReleaseGPUBuffer(gpu, vertex_buf)
    sdl.ReleaseGPUBuffer(gpu, index_buf)
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline_game)
    sdl.ReleaseWindowFromGPUDevice(gpu, win)
    sdl.DestroyGPUDevice(gpu)
}

render_set_shader :: proc() {
    sdl.BindGPUGraphicsPipeline(render_pass, pipeline_game)
}

render_update_viewport :: proc(width, height: i32) {
    resolution = {f32(width), f32(height)}
}

@(private="file")
create_quad :: proc() {
    vertices := []Vertex_Data {
        {{0, 1}, {0, 0}},
        {{1, 1}, {1, 0}},
        {{0, 0}, {0, 1}},
        {{1, 0}, {1, 1}},
    }

    indices := []u16 {
        0, 1, 2,
        2, 1, 3,
     }

    vert_size := u32(len(vertices) * size_of(vertices[0]))
    vertex_buf = sdl.CreateGPUBuffer(gpu, {
        usage = {.VERTEX},
        size = vert_size,
    })
    index_size := u32(len(indices) * size_of(indices[0]))
    index_buf = sdl.CreateGPUBuffer(gpu, {
        usage = {.INDEX},
        size = index_size,
    })
    trans_buf := sdl.CreateGPUTransferBuffer(gpu, {
        usage = .UPLOAD,
        size = vert_size + index_size,
    })
    trans_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(gpu, trans_buf, false)
    mem.copy(trans_mem, raw_data(vertices), int(vert_size))
    mem.copy(trans_mem[vert_size:], raw_data(indices), int(index_size))
    sdl.UnmapGPUTransferBuffer(gpu, trans_buf)
    copy_cmd_buf := sdl.AcquireGPUCommandBuffer(gpu)
    copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buf)
    sdl.UploadToGPUBuffer(copy_pass, {trans_buf, 0}, {vertex_buf, 0, vert_size}, false)
    sdl.UploadToGPUBuffer(copy_pass, {trans_buf, vert_size}, {index_buf, 0, index_size}, false)
    sdl.EndGPUCopyPass(copy_pass)
    if !sdl.SubmitGPUCommandBuffer(copy_cmd_buf) {
        panic("Cant submit GPU cmd buffer")
    }
    sdl.ReleaseGPUTransferBuffer(gpu, trans_buf)
}

@(private="file")
shader_create :: proc(shader_data: []u8, stage: sdl.GPUShaderStage, buffers: u32,
                      samplers: u32, format: sdl.GPUShaderFormat, entrypoint: cstring = "main") -> ^sdl.GPUShader {
    shader := sdl.CreateGPUShader(gpu, {
        code_size = len(shader_data),
        code = raw_data(shader_data),
        entrypoint = entrypoint,
        format = format,
        stage = stage,
        num_uniform_buffers = buffers,
        num_samplers = samplers,
    })
    return shader
}

texture_from_sprite :: proc(data: []u8) -> (u32, int, int) {
    image, err := png.load_from_bytes(data)
    assert(err == nil, "Failed to load image.")
    alpha_ok := libimage.alpha_add_if_missing(image)
    assert(alpha_ok, "Failed to guarantee there's an alpha channel.")
    assert(image.channels == 4 && image.depth == 8, "Bad image format.")
    assert(image.pixels.off == 0, "Probably not good, whatever it means.")
    defer png.destroy(image)

    tex := texture_create(u32(image.width), u32(image.height), &image.pixels.buf[0], 4)
    return tex, image.width, image.height
}

texture_create :: proc(w: u32, h: u32, data: rawptr, size: u32) -> u32 {
    tex_format :sdl.GPUTextureFormat= .B5G5R5A1_UNORM
    if(size == 4) {
        tex_format = .R8G8B8A8_UNORM
    }
    textures[texture_id].texture = sdl.CreateGPUTexture(gpu, {
        type = .D2,
        format = tex_format,
        usage = {.SAMPLER},
        width = w,
        height = h,
        layer_count_or_depth = 1,
        num_levels = 1,
    })
    tex_size := w * h * size
    trans_buf := sdl.CreateGPUTransferBuffer(gpu, {
        usage = .UPLOAD,
        size = tex_size,
    })
    trans_mem := sdl.MapGPUTransferBuffer(gpu, trans_buf, false)
    mem.copy(trans_mem, data, int(tex_size))
    sdl.UnmapGPUTransferBuffer(gpu, trans_buf)
    copy_cmd_buf := sdl.AcquireGPUCommandBuffer(gpu)
    copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buf)
    sdl.UploadToGPUTexture(copy_pass, {transfer_buffer = trans_buf},
        {
            texture = textures[texture_id].texture,
            w = w,
            h = h,
            d = 1,
        }, false)
    sdl.EndGPUCopyPass(copy_pass)
    if !sdl.SubmitGPUCommandBuffer(copy_cmd_buf) {
        panic("Cant submit GPU cmd buffer")
    }
    sdl.ReleaseGPUTransferBuffer(gpu, trans_buf)
    textures[texture_id].sampler = sdl.CreateGPUSampler(gpu, {})
    tmp_id := texture_id
    texture_id += 1
    return tmp_id
}

texture_destroy :: proc(texture: u32) {
    sdl.ReleaseGPUSampler(gpu, textures[texture].sampler)
    sdl.ReleaseGPUTexture(gpu, textures[texture].texture)
    texture_id -= 1
}

render_pre :: proc() {
    cmd_buf = sdl.AcquireGPUCommandBuffer(gpu)
    swap_text: ^sdl.GPUTexture
    if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buf, win, &swap_text, nil, nil) {
        panic("Failed to acquire swapchain texture")
    }

    if swap_text != nil {
        color_info := sdl.GPUColorTargetInfo {
            texture = swap_text,
            load_op = .CLEAR,
            clear_color = {0.098, 0.07, 0.059, 1.0},
            store_op = .STORE,
        }
        render_pass = sdl.BeginGPURenderPass(cmd_buf, &color_info, 1, nil)
        sdl.BindGPUVertexBuffers(render_pass, 0, &(sdl.GPUBufferBinding {buffer = vertex_buf}), 1)
        sdl.BindGPUIndexBuffer(render_pass, {buffer = index_buf}, ._16BIT)
    } else {
        render_pass = nil
    }
}

render_quad :: proc(data: Render_data) {
    if render_pass != nil {
        ui_frag_uniform :Ui_frag_uniform= {data.scale, data.offset, data.color}
        sdl.PushGPUFragmentUniformData(cmd_buf, 0, &ui_frag_uniform, size_of(ui_frag_uniform))
        
        model_matrix := linalg.matrix4_scale_f32({data.size.x, data.size.y, 0})
        model_matrix = linalg.matrix4_translate_f32({data.position.x, data.position.y, 0}) * model_matrix
        ui_vert_uniform :Ui_vert_uniform= {model_matrix, resolution, camera_position, data.flip}
        sdl.PushGPUVertexUniformData(cmd_buf, 0, &ui_vert_uniform, size_of(ui_vert_uniform))

        sdl.BindGPUFragmentSamplers(render_pass, 0, &textures[data.texture], 1)
        sdl.DrawGPUIndexedPrimitives(render_pass, 6, 1, 0, 0, 0)
    }
}

render_post :: proc() {
    sdl.EndGPURenderPass(render_pass)
    if !sdl.SubmitGPUCommandBuffer(cmd_buf) {
        panic("Cant submit GPU cmd buffer")
    }
}

// Doesn't rely on Open GL, but still a natural place here.
render_text :: proc(font: Sprite2, text: string, position: Vector2f, 
      size: Vector2f = {0, 0}, color: Vector4f = {1, 1, 1, 1}) {
    assert(font.frames.x * font.frames.y > 96, "Has all printable ASCII characters")

    real_size := Vector2f{f32(font.width) / font.frames.x, f32(font.height) / font.frames.y}
    scale: Vector2f = {real_size.x / f32(font.width), real_size.y / f32(font.height)}
    if linalg.vector_length(size) != 0 {
        real_size = size
    }

    bytes := raw_data(text)[:len(text)]
    new_pos := position
    for b, _ in bytes {
        x := (b - 32) % u8(font.frames.x)
        y := (b - 32) / u8(font.frames.x)
        if b == 10 {
            new_pos.y -= size.y + 2
            new_pos.x = position.x
            continue
        }

        render_quad({
            texture = font.texture,
            position = {new_pos.x, new_pos.y},
            size = real_size,
            scale = scale,
            offset = {scale.x * f32(x), scale.y * f32(y)},
            flip = {0, 0},
            color = color,
        },)
        new_pos.x += real_size.x
    }
}

render_set_camera :: proc(x: f32 = camera_position.x, y: f32 = camera_position.y) {
    camera_position = {x, y}
}

render_get_camera :: proc() -> Vector2f {
    return camera_position
}
