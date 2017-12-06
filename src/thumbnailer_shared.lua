local Thumbnailer = {
    cache_directory = thumbnailer_options.cache_directory,

    state = {
        ready = false,
        available = false,
        enabled = false,

        thumbnail_template = nil,

        thumbnail_delta = nil,
        thumbnail_count = 0,

        thumbnail_size = nil,

        finished_thumbnails = 0,
        thumbnails = {}
    }
}

function Thumbnailer:clear_state()
    clear_table(self.state)
    self.state.ready = false
    self.state.available = false
    self.state.finished_thumbnails = 0
    self.state.thumbnails = {}
end


function Thumbnailer:on_file_loaded()
    self:clear_state()
end

function Thumbnailer:on_thumb_ready(index)
    self.state.thumbnails[index] = true

    -- Recount (just in case)
    self.state.finished_thumbnails = 0
    for i in pairs(self.state.thumbnails) do
        self.state.finished_thumbnails = self.state.finished_thumbnails + 1
    end
end

function Thumbnailer:on_video_change(params)
    self:clear_state()
    if params ~= nil then
        if not self.state.ready then
            self:update_state()
        end
    end
end


function Thumbnailer:update_state()
    self.state.thumbnail_delta = self:get_delta()
    self.state.thumbnail_count = self:get_thumbnail_count()

    self.state.thumbnail_template = self:get_thumbnail_template()
    self.state.thumbnail_size = self:get_thumbnail_size()

    self.state.ready = true

    local file_path = mp.get_property_native("path")
    self.state.is_remote = file_path:find("://") ~= nil

    self.state.available = false

    -- Make sure the file has video (and not just albumart)
    local track_list = mp.get_property_native("track-list")
    local has_video = false
    for i, track in pairs(track_list) do
        if track.type == "video" and not track.external and not track.albumart then
            has_video = true
            break
        end
    end

    if has_video and self.state.thumbnail_delta ~= nil and self.state.thumbnail_size ~= nil and self.state.thumbnail_count > 0 then
        self.state.available = true
    end

end


function Thumbnailer:get_thumbnail_template()
    local file_path = mp.get_property_native("path")
    local is_remote = file_path:find("://") ~= nil

    local filename = mp.get_property_native("filename/no-ext")
    local filesize = mp.get_property_native("file-size", 0)

    if is_remote then
        filesize = 0
    end

    filename = filename:gsub('[^a-zA-Z0-9_.%-\' ]', '')

    local file_key = ("%s-%d"):format(filename, filesize)
    local file_template = join_paths(self.cache_directory, file_key, "%06d.bgra")
    return file_template
end


function Thumbnailer:get_thumbnail_size()
    local video_dec_params = mp.get_property_native("video-dec-params")
    local video_width = video_dec_params.dw
    local video_height = video_dec_params.dh
    if not (video_width and video_height) then
        return nil
    end

    local w, h
    if video_width > video_height then
        w = thumbnailer_options.thumbnail_width
        h = math.floor(video_height * (w / video_width))
    else
        h = thumbnailer_options.thumbnail_height
        w = math.floor(video_width * (h / video_height))
    end
    return { w=w, h=h }
end


function Thumbnailer:get_delta()
    local file_path = mp.get_property_native("path")
    local file_duration = mp.get_property_native("duration")
    local is_seekable = mp.get_property_native("seekable")

    -- Naive url check
    local is_remote = file_path:find("://") ~= nil

    local remote_and_disallowed = is_remote
    if is_remote and thumbnailer_options.thumbnail_network then
        remote_and_disallowed = false
    end

    if remote_and_disallowed or not is_seekable or not file_duration then
        -- Not a local path (or remote thumbnails allowed), not seekable or lacks duration
        return nil
    end

    local thumbnail_count = thumbnailer_options.thumbnail_count
    local min_delta = thumbnailer_options.min_delta
    local max_delta = thumbnailer_options.max_delta

    if is_remote then
        thumbnail_count = thumbnailer_options.remote_thumbnail_count
        min_delta = thumbnailer_options.remote_min_delta
        max_delta = thumbnailer_options.remote_max_delta
    end

    local target_delta = (file_duration / thumbnail_count)
    local delta = math.max(min_delta, math.min(max_delta, target_delta))

    return delta
end


function Thumbnailer:get_thumbnail_count()
    local delta = self:get_delta()
    if delta == nil then
        return 0
    end
    local file_duration = mp.get_property_native("duration")

    return math.floor(file_duration / delta)
end

function Thumbnailer:get_closest(thumbnail_index)
    local min_distance = self.state.thumbnail_count+1
    local closest = nil

    for index, value in pairs(self.state.thumbnails) do
        local distance = math.abs(index - thumbnail_index)
        if distance < min_distance then
            min_distance = distance
            closest = index
        end
    end
    return closest, min_distance
end

function Thumbnailer:get_thumbnail_path(time_position)
    local thumbnail_index = math.min(math.floor(time_position / self.state.thumbnail_delta), self.state.thumbnail_count-1)

    local closest, distance = self:get_closest(thumbnail_index)

    if closest ~= nil then
        return self.state.thumbnail_template:format(closest), thumbnail_index, closest
    else
        return nil, thumbnail_index, nil
    end
end

function Thumbnailer:register_client()
    mp.register_script_message("mpv_thumbnail_script-ready", function(index, path) self:on_thumb_ready(tonumber(index), path) end)
    -- Wait for server to tell us we're live
    mp.register_script_message("mpv_thumbnail_script-enabled", function() self.state.enabled = true end)

    -- Notify server to generate thumbnails when video loads/changes
    mp.observe_property("video-dec-params", "native", function()
        local duration = mp.get_property_native("duration")
        local max_duration = thumbnailer_options.autogenerate_max_duration

        if duration and thumbnailer_options.autogenerate then
            -- Notify if autogenerate is on and video is not too long
            if duration < max_duration or max_duration == 0 then
                mp.commandv("script-message", "mpv_thumbnail_script-generate")
            end
        end
    end)
end

mp.observe_property("video-dec-params", "native", function(name, params) Thumbnailer:on_video_change(params) end)
