// - [ ] Test helpers
// - [ ] Body reading
//   - [ ] Form data
//   - [ ] Multipart
//   - [ ] Json
//   - [x] String
//   - [x] Bit string
// - [ ] Body writing
//   - [x] Html
//   - [x] Json
// - [x] Static files
// - [ ] Cookies
//   - [ ] Signed cookies
// - [ ] Secret keys
//   - [ ] Key rotation
// - [ ] Sessions
// - [ ] Flash messages
// - [ ] Websockets
// - [ ] CSRF
// - [ ] Project generators
// - [x] Exception recovery

import gleam/string_builder.{StringBuilder}
import gleam/bit_builder.{BitBuilder}
import gleam/bit_string
import gleam/erlang
import gleam/dynamic.{Dynamic}
import gleam/bool
import gleam/http.{Method}
import gleam/http/request.{Request as HttpRequest}
import gleam/http/response.{Response as HttpResponse}
import gleam/list
import gleam/result
import gleam/string
import gleam/option.{Option}
import gleam/uri
import gleam/io
import gleam/int
import simplifile
import mist

//
// Running the server
//

// TODO: test
// TODO: document
pub fn mist_service(
  service: fn(Request) -> Response,
) -> fn(HttpRequest(mist.Connection)) -> HttpResponse(mist.ResponseData) {
  fn(request: HttpRequest(_)) {
    let connection = make_connection(mist_body_reader(request))
    let request = request.set_body(request, connection)
    let response =
      request
      |> service
      |> mist_response

    // TODO: use some FFI to ensure this always happens, even if there is a crash
    let assert Ok(_) = delete_temporary_files(request)

    response
  }
}

fn mist_body_reader(request: HttpRequest(mist.Connection)) -> Reader {
  case mist.stream(request) {
    Error(_) -> fn(_) { Ok(ReadingFinished) }
    Ok(stream) -> fn(size) { wrap_mist_chunk(stream(size)) }
  }
}

fn wrap_mist_chunk(
  chunk: Result(mist.Chunk, mist.ReadError),
) -> Result(Read, Nil) {
  chunk
  |> result.nil_error
  |> result.map(fn(chunk) {
    case chunk {
      mist.Done -> ReadingFinished
      mist.Chunk(data, consume) ->
        Chunk(data, fn(size) { wrap_mist_chunk(consume(size)) })
    }
  })
}

fn mist_response(response: Response) -> HttpResponse(mist.ResponseData) {
  let body = case response.body {
    Empty -> mist.Bytes(bit_builder.new())
    Text(text) -> mist.Bytes(bit_builder.from_string_builder(text))
    File(path) -> mist_send_file(path)
  }
  response
  |> response.set_body(body)
}

fn mist_send_file(path: String) -> mist.ResponseData {
  case mist.send_file(path, offset: 0, limit: option.None) {
    Ok(body) -> body
    Error(error) -> {
      // TODO: log error
      io.println("ERROR: " <> string.inspect(error))
      // TODO: return 500
      mist.Bytes(bit_builder.new())
    }
  }
}

//
// Responses
//

pub type ResponseBody {
  Empty
  // TODO: remove content type
  File(path: String)
  Text(StringBuilder)
}

/// An alias for a HTTP response containing a `ResponseBody`.
pub type Response =
  HttpResponse(ResponseBody)

// TODO: document
pub fn response(status: Int) -> Response {
  HttpResponse(status, [], Empty)
}

// TODO: test
// TODO: document
pub fn set_body(response: Response, body: ResponseBody) -> Response {
  response
  |> response.set_body(body)
}

// TODO: test
// TODO: document
pub fn html_response(html: StringBuilder, status: Int) -> Response {
  HttpResponse(status, [#("content-type", "text/html")], Text(html))
}

// TODO: document
pub fn html_body(response: Response, html: StringBuilder) -> Response {
  response
  |> response.set_body(Text(html))
  |> response.set_header("content-type", "text/html")
}

// TODO: document
pub fn method_not_allowed(permitted: List(Method)) -> Response {
  let allowed =
    permitted
    |> list.map(http.method_to_string)
    |> list.sort(string.compare)
    |> string.join(", ")
    |> string.uppercase
  HttpResponse(405, [#("allow", allowed)], Empty)
}

// TODO: document
pub fn ok() -> Response {
  HttpResponse(200, [], Empty)
}

// TODO: document
pub fn created() -> Response {
  HttpResponse(201, [], Empty)
}

// TODO: document
pub fn accepted() -> Response {
  HttpResponse(202, [], Empty)
}

// TODO: document
pub fn no_content() -> Response {
  HttpResponse(204, [], Empty)
}

// TODO: document
pub fn not_found() -> Response {
  HttpResponse(404, [], Empty)
}

// TODO: document
pub fn bad_request() -> Response {
  HttpResponse(400, [], Empty)
}

// TODO: document
pub fn entity_too_large() -> Response {
  HttpResponse(413, [], Empty)
}

// TODO: document
pub fn internal_server_error() -> Response {
  HttpResponse(500, [], Empty)
}

//
// Requests
//

pub opaque type Connection {
  Connection(
    reader: Reader,
    // TODO: document these. Cannot be here as this is opaque.
    max_body_size: Int,
    max_files_size: Int,
    read_chunk_size: Int,
    temporary_directory: String,
  )
}

fn make_connection(body_reader: Reader) -> Connection {
  Connection(
    reader: body_reader,
    max_body_size: 8_000_000,
    max_files_size: 32_000_000,
    read_chunk_size: 1_000_000,
    // TODO: replace with random string in suitable location
    temporary_directory: "./tmp/123",
  )
}

type BufferedReader {
  BufferedReader(reader: Reader, buffer: BitString)
}

type Quotas {
  Quotas(body: Int, files: Int)
}

fn decrement_body_quota(quotas: Quotas, size: Int) -> Result(Quotas, Response) {
  let quotas = Quotas(..quotas, body: quotas.body - size)
  case quotas.body < 0 {
    True -> Error(entity_too_large())
    False -> Ok(quotas)
  }
}

fn decrement_quota(quota: Int, size: Int) -> Result(Int, Response) {
  case quota - size {
    quota if quota < 0 -> Error(entity_too_large())
    quota -> Ok(quota)
  }
}

fn buffered_read(reader: BufferedReader, chunk_size: Int) -> Result(Read, Nil) {
  case reader.buffer {
    <<>> -> reader.reader(chunk_size)
    _ -> Ok(Chunk(reader.buffer, reader.reader))
  }
}

type Reader =
  fn(Int) -> Result(Read, Nil)

type Read {
  Chunk(BitString, next: Reader)
  ReadingFinished
}

// TODO: document
pub fn set_max_body_size(request: Request, size: Int) -> Request {
  Connection(..request.body, max_body_size: size)
  |> request.set_body(request, _)
}

// TODO: document
pub fn get_max_body_size(request: Request) -> Int {
  request.body.max_body_size
}

// TODO: document
pub fn set_max_files_size(request: Request, size: Int) -> Request {
  Connection(..request.body, max_files_size: size)
  |> request.set_body(request, _)
}

// TODO: document
pub fn get_max_files_size(request: Request) -> Int {
  request.body.max_files_size
}

// TODO: document
pub fn set_read_chunk_size(request: Request, size: Int) -> Request {
  Connection(..request.body, read_chunk_size: size)
  |> request.set_body(request, _)
}

// TODO: document
pub fn get_read_chunk_size(request: Request) -> Int {
  request.body.read_chunk_size
}

pub type Request =
  HttpRequest(Connection)

// TODO: document
pub fn require_method(
  request: HttpRequest(t),
  method: Method,
  next: fn() -> Response,
) -> Response {
  case request.method == method {
    True -> next()
    False -> method_not_allowed([method])
  }
}

// TODO: re-export once Gleam has a syntax for that
/// Return the non-empty segments of a request path.
/// 
/// # Examples
///
/// ```gleam
/// > request.new()
/// > |> request.set_path("/one/two/three")
/// > |> wisp.path_segments
/// ["one", "two", "three"]
/// ```
///
pub const path_segments = request.path_segments

/// This function overrides an incoming POST request with a method given in
/// the request's `_method` query paramerter. This is useful as web browsers
/// typically only support GET and POST requests, but our application may
/// expect other HTTP methods that are more semantically correct.
///
/// The methods PUT, PATCH, and DELETE are accepted for overriding, all others
/// are ignored.
///
/// The `_method` query paramerter can be specified in a HTML form like so:
///
///    <form method="POST" action="/item/1?_method=DELETE">
///      <button type="submit">Delete item</button>
///    </form>
///
pub fn method_override(request: HttpRequest(a)) -> HttpRequest(a) {
  use <- bool.guard(when: request.method != http.Post, return: request)
  {
    use query <- result.try(request.get_query(request))
    use pair <- result.try(list.key_pop(query, "_method"))
    use method <- result.map(http.parse_method(pair.0))

    case method {
      http.Put | http.Patch | http.Delete -> request.set_method(request, method)
      _ -> request
    }
  }
  |> result.unwrap(request)
}

// TODO: don't always return entity to large. Other errors are possible, such as
// network errors.
// TODO: document
// TODO: note you probably want a `require_` function
// TODO: note it'll hang if you call it twice
// TODO: note it respects the max body size
pub fn require_string_body(
  request: Request,
  next: fn(String) -> Response,
) -> Response {
  case read_entire_body(request) {
    Ok(body) -> require(bit_string.to_string(body), next)
    Error(_) -> entity_too_large()
  }
}

// Should we make this public?
fn read_entire_body(request: Request) -> Result(BitString, Nil) {
  let connection = request.body
  read_body_loop(
    connection.reader,
    connection.read_chunk_size,
    connection.max_body_size,
    <<>>,
  )
}

fn read_body_loop(
  reader: Reader,
  read_chunk_size: Int,
  max_body_size: Int,
  accumulator: BitString,
) -> Result(BitString, Nil) {
  use chunk <- result.try(reader(read_chunk_size))
  case chunk {
    ReadingFinished -> Ok(accumulator)
    Chunk(chunk, next) -> {
      let accumulator = bit_string.append(accumulator, chunk)
      case bit_string.byte_size(accumulator) > max_body_size {
        True -> Error(Nil)
        False ->
          read_body_loop(next, read_chunk_size, max_body_size, accumulator)
      }
    }
  }
}

// TODO: make private and replace with a generic require_form function
// TODO: test
// TODO: document
pub fn require_form_urlencoded_body(
  request: Request,
  next: fn(FormData) -> Response,
) -> Response {
  use body <- require_string_body(request)
  use pairs <- require(uri.parse_query(body))
  let pairs = sort_keys(pairs)
  next(FormData(values: pairs, files: []))
}

// TODO: make private and replace with a generic require_form function
// TODO: test
// TODO: document
pub fn require_multipart_body(
  request: Request,
  boundary: String,
  next: fn(FormData) -> Response,
) -> Response {
  let quotas =
    Quotas(files: request.body.max_files_size, body: request.body.max_body_size)
  let reader = BufferedReader(request.body.reader, <<>>)

  let result =
    read_multipart(request, reader, boundary, quotas, FormData([], []))
  case result {
    Ok(form_data) -> next(form_data)
    Error(response) -> response
  }
}

fn read_multipart(
  request: Request,
  reader: BufferedReader,
  boundary: String,
  quotas: Quotas,
  data: FormData,
) -> Result(FormData, Response) {
  let read_size = request.body.read_chunk_size

  // First we read the headers of the multipart part.
  let header_parser =
    fn_with_bad_request_error(http.parse_multipart_headers(_, boundary))
  let result = multipart_headers(reader, header_parser, read_size, quotas)
  use #(headers, reader, quotas) <- result.try(result)
  use #(name, filename) <- result.try(multipart_content_disposition(headers))

  // Then we read the body of the part.
  let parse = fn_with_bad_request_error(http.parse_multipart_body(_, boundary))
  use #(data, reader, quotas) <- result.try(case filename {
    // There is a file name, so we treat this as a file upload, streaming the
    // contents to a temporary file and using the dedicated files size quota.
    option.Some(file_name) -> {
      use path <- result.try(or_500(new_temporary_file(request)))
      let append = multipart_file_append
      let q = quotas.files
      let result =
        multipart_body(reader, parse, boundary, read_size, q, append, path)
      use #(reader, quota, _) <- result.map(result)
      let quotas = Quotas(..quotas, files: quota)
      let file = UploadedFile(path: path, file_name: file_name)
      let data = FormData(..data, files: [#(name, file), ..data.files])
      #(data, reader, quotas)
    }

    // No file name, this is a regular form value that we hold in memory.
    option.None -> {
      let append = fn(data, chunk) { Ok(bit_string.append(data, chunk)) }
      let q = quotas.body
      let result =
        multipart_body(reader, parse, boundary, read_size, q, append, <<>>)
      use #(reader, quota, value) <- result.try(result)
      let quotas = Quotas(..quotas, body: quota)
      use value <- result.map(bit_string_to_string(value))
      let data = FormData(..data, values: [#(name, value), ..data.values])
      #(data, reader, quotas)
    }
  })

  case reader {
    // There's at least one more part, read it.
    option.Some(reader) ->
      read_multipart(request, reader, boundary, quotas, data)
    // There are no more parts, we're done.
    option.None -> Ok(FormData(sort_keys(data.values), sort_keys(data.files)))
  }
}

fn bit_string_to_string(bits: BitString) -> Result(String, Response) {
  bit_string.to_string(bits)
  |> result.replace_error(bad_request())
}

fn multipart_file_append(
  path: String,
  chunk: BitString,
) -> Result(String, Response) {
  chunk
  |> simplifile.append_bits(path)
  |> or_500
  |> result.replace(path)
}

fn or_500(result: Result(a, b)) -> Result(a, Response) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> {
      // TODO: log error
      io.println("ERROR: " <> string.inspect(error))
      Error(internal_server_error())
    }
  }
}

fn multipart_body(
  reader: BufferedReader,
  parse: fn(BitString) -> Result(http.MultipartBody, Response),
  boundary: String,
  chunk_size: Int,
  quota: Int,
  append: fn(t, BitString) -> Result(t, Response),
  data: t,
) -> Result(#(Option(BufferedReader), Int, t), Response) {
  use #(chunk, reader) <- result.try(read_chunk(reader, chunk_size))
  use output <- result.try(parse(chunk))

  case output {
    http.MultipartBody(chunk, done, remaining) -> {
      let used = bit_string.byte_size(chunk) - bit_string.byte_size(remaining)
      use quotas <- result.try(decrement_quota(quota, used))
      let reader = BufferedReader(reader, remaining)
      let reader = case done {
        True -> option.None
        False -> option.Some(reader)
      }
      use value <- result.map(append(data, chunk))
      #(reader, quotas, value)
    }

    http.MoreRequiredForBody(chunk, parse) -> {
      let parse = fn_with_bad_request_error(parse(_))
      let reader = BufferedReader(reader, <<>>)
      use data <- result.try(append(data, chunk))
      multipart_body(reader, parse, boundary, chunk_size, quota, append, data)
    }
  }
}

fn fn_with_bad_request_error(
  f: fn(a) -> Result(b, c),
) -> fn(a) -> Result(b, Response) {
  fn(a) {
    f(a)
    |> result.replace_error(bad_request())
  }
}

fn multipart_content_disposition(
  headers: List(http.Header),
) -> Result(#(String, Option(String)), Response) {
  {
    use header <- result.try(list.key_find(headers, "content-disposition"))
    use header <- result.try(http.parse_content_disposition(header))
    use name <- result.map(list.key_find(header.parameters, "name"))
    let filename =
      option.from_result(list.key_find(header.parameters, "filename"))
    #(name, filename)
  }
  |> result.replace_error(bad_request())
}

fn read_chunk(
  reader: BufferedReader,
  chunk_size: Int,
) -> Result(#(BitString, Reader), Response) {
  buffered_read(reader, chunk_size)
  |> result.replace_error(bad_request())
  |> result.try(fn(chunk) {
    case chunk {
      Chunk(chunk, next) -> Ok(#(chunk, next))
      ReadingFinished -> Error(bad_request())
    }
  })
}

fn multipart_headers(
  reader: BufferedReader,
  parse: fn(BitString) -> Result(http.MultipartHeaders, Response),
  chunk_size: Int,
  quotas: Quotas,
) -> Result(#(List(http.Header), BufferedReader, Quotas), Response) {
  use #(chunk, reader) <- result.try(read_chunk(reader, chunk_size))
  use headers <- result.try(parse(chunk))

  case headers {
    http.MultipartHeaders(headers, remaining) -> {
      let used = bit_string.byte_size(chunk) - bit_string.byte_size(remaining)
      use quotas <- result.map(decrement_body_quota(quotas, used))
      let reader = BufferedReader(reader, remaining)
      #(headers, reader, quotas)
    }
    http.MoreRequiredForHeaders(parse) -> {
      let parse = fn(chunk) {
        parse(chunk)
        |> result.replace_error(bad_request())
      }
      let reader = BufferedReader(reader, <<>>)
      multipart_headers(reader, parse, chunk_size, quotas)
    }
  }
}

fn sort_keys(pairs: List(#(String, t))) -> List(#(String, t)) {
  list.sort(pairs, fn(a, b) { string.compare(a.0, b.0) })
}

// TODO: document
pub fn require(
  result: Result(value, error),
  next: fn(value) -> Response,
) -> Response {
  case result {
    Ok(value) -> next(value)
    Error(_) -> bad_request()
  }
}

pub type FormData {
  FormData(
    values: List(#(String, String)),
    files: List(#(String, UploadedFile)),
  )
}

pub type UploadedFile {
  UploadedFile(file_name: String, path: String)
}

//
// MIME types
//

// TODO: move to another package
fn extension_to_mime_type(extension: String) -> String {
  case extension {
    "7z" -> "application/x-7z-compressed"
    "aac" -> "audio/aac"
    "abw" -> "application/x-abiword"
    "ai" -> "application/postscript"
    "arc" -> "application/x-freearc"
    "asice" -> "application/vnd.etsi.asic-e+zip"
    "asics" -> "application/vnd.etsi.asic-s+zip"
    "atom" -> "application/atom+xml"
    "avi" -> "video/x-msvideo"
    "avif" -> "image/avif"
    "azw" -> "application/vnd.amazon.ebook"
    "bin" -> "application/octet-stream"
    "bmp" -> "image/bmp"
    "bz" -> "application/x-bzip"
    "bz2" -> "application/x-bzip2"
    "cda" -> "application/x-cdf"
    "csh" -> "application/x-csh"
    "css" -> "text/css"
    "csv" -> "text/csv"
    "doc" -> "application/msword"
    "docx" ->
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    "eot" -> "application/vnd.ms-fontobject"
    "eps" -> "application/postscript"
    "epub" -> "application/epub+zip"
    "gif" -> "image/gif"
    "gz" -> "application/gzip"
    "heic" -> "image/heic"
    "heif" -> "image/heif"
    "htm" -> "text/html"
    "html" -> "text/html"
    "ico" -> "image/vnd.microsoft.icon"
    "ics" -> "text/calendar"
    "jar" -> "application/java-archive"
    "jpeg" -> "image/jpeg"
    "jpg" -> "image/jpeg"
    "js" -> "text/javascript"
    "json" -> "application/json"
    "json-api" -> "application/vnd.api+json"
    "json-patch" -> "application/json-patch+json"
    "jsonld" -> "application/ld+json"
    "jxl" -> "image/jxl"
    "markdown" -> "text/markdown"
    "md" -> "text/markdown"
    "mdb" -> "application/x-msaccess"
    "mid" -> "audio/midi"
    "midi" -> "audio/midi"
    "mjs" -> "text/javascript"
    "mov" -> "video/quicktime"
    "mp3" -> "audio/mpeg"
    "mp4" -> "video/mp4"
    "mpeg" -> "video/mpeg"
    "mpg" -> "video/mpeg"
    "mpkg" -> "application/vnd.apple.installer+xml"
    "odp" -> "application/vnd.oasis.opendocument.presentation"
    "ods" -> "application/vnd.oasis.opendocument.spreadsheet"
    "odt" -> "application/vnd.oasis.opendocument.text"
    "oga" -> "audio/ogg"
    "ogv" -> "video/ogg"
    "ogx" -> "application/ogg"
    "opus" -> "audio/opus"
    "otf" -> "font/otf"
    "pdf" -> "application/pdf"
    "php" -> "application/x-httpd-php"
    "png" -> "image/png"
    "ppt" -> "application/vnd.ms-powerpoint"
    "pptx" ->
      "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    "ps" -> "application/postscript"
    "psd" -> "image/vnd.adobe.photoshop"
    "rar" -> "application/vnd.rar"
    "rss" -> "application/rss+xml"
    "rtf" -> "application/rtf"
    "sce" -> "application/vnd.etsi.asic-e+zip"
    "scs" -> "application/vnd.etsi.asic-s+zip"
    "sh" -> "application/x-sh"
    "svg" -> "image/svg+xml"
    "svgz" -> "image/svg+xml"
    "swf" -> "application/x-shockwave-flash"
    "tar" -> "application/x-tar"
    "text" -> "text/plain"
    "tif" -> "image/tiff"
    "tiff" -> "image/tiff"
    "ts" -> "video/mp2t"
    "ttf" -> "font/ttf"
    "txt" -> "text/plain"
    "vsd" -> "application/vnd.visio"
    "wasm" -> "application/wasm"
    "wav" -> "audio/wav"
    "weba" -> "audio/webm"
    "webm" -> "video/webm"
    "webmanifest" -> "application/manifest+json"
    "webp" -> "image/webp"
    "wmv" -> "video/x-ms-wmv"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "xhtml" -> "application/xhtml+xml"
    "xls" -> "application/vnd.ms-excel"
    "xlsx" ->
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    "xml" -> "application/xml"
    "xul" -> "application/vnd.mozilla.xul+xml"
    "zip" -> "application/zip"
    _ -> "application/octet-stream"
  }
}

//
// Middleware
//

// TODO: document
pub fn rescue_crashes(service: fn() -> Response) -> Response {
  case erlang.rescue(service) {
    Ok(response) -> response
    Error(error) -> {
      // TODO: log the error
      io.println("ERROR: " <> string.inspect(error))
      internal_server_error()
    }
  }
}

// TODO: test
// TODO: document
// TODO: real implementation that uses the logger
pub fn log_requests(req: Request, service: fn() -> Response) -> Response {
  let response = service()
  [
    int.to_string(response.status),
    " ",
    string.uppercase(http.method_to_string(req.method)),
    " ",
    req.path,
  ]
  |> string.concat
  |> io.println
  response
}

fn remove_preceeding_slashes(string: String) -> String {
  case string {
    "/" <> rest -> remove_preceeding_slashes(rest)
    _ -> string
  }
}

// TODO: replace with simplifile function when it exists
fn join_path(a: String, b: String) -> String {
  let b = remove_preceeding_slashes(b)
  case string.ends_with(a, "/") {
    True -> a <> b
    False -> a <> "/" <> b
  }
}

// TODO: document
pub fn serve_static(
  req: Request,
  under prefix: String,
  from directory: String,
  next service: fn() -> Response,
) -> Response {
  let path = remove_preceeding_slashes(req.path)
  let prefix = remove_preceeding_slashes(prefix)
  case req.method, string.starts_with(path, prefix) {
    http.Get, True -> {
      let path =
        path
        |> string.drop_left(string.length(prefix))
        |> string.replace(each: "..", with: "")
        |> join_path(directory, _)

      let mime_type =
        req.path
        |> string.split(on: ".")
        |> list.last
        |> result.unwrap("")
        |> extension_to_mime_type

      // TODO: better check for file existence.
      case file_info(path) {
        Error(_) -> service()
        Ok(_) ->
          response.new(200)
          |> response.set_header("content-type", mime_type)
          |> response.set_body(File(path))
      }
    }
    _, _ -> service()
  }
}

//
// File uploads
//

// TODO: test
// TODO: document
// TODO: document that you need to call `remove_temporary_files` when you're
// done, unless you're using `mist_service` which will do it for you.
pub fn new_temporary_file(
  request: Request,
) -> Result(String, simplifile.FileError) {
  let directory = request.body.temporary_directory
  use _ <- result.try(simplifile.make_directory(directory))
  // TODO: use a random filename
  let path = directory <> "file.tmp"
  // TODO: use create_file when simplifile has it
  use _ <- result.map(simplifile.write_bits(<<>>, to: path))
  path
}

// TODO: test
// TODO: document
pub fn delete_temporary_files(
  request: Request,
) -> Result(Nil, simplifile.FileError) {
  case simplifile.delete_directory(request.body.temporary_directory) {
    Error(simplifile.Enoent) -> Ok(Nil)
    other -> other
  }
}

@external(erlang, "file", "read_file_info")
fn file_info(path: String) -> Result(Dynamic, Dynamic)

//
// Testing
//

// TODO: test
// TODO: document
// TODO: chunk the body
pub fn test_connection(body: BitString) -> Connection {
  make_connection(fn(_size) {
    Ok(Chunk(body, fn(_size) { Ok(ReadingFinished) }))
  })
}

// TODO: better API
// TODO: test
// TODO: document
pub fn test_request(body: BitString) -> Request {
  request.new()
  |> request.set_body(test_connection(body))
}

// TODO: test
// TODO: document
pub fn body_to_string_builder(body: ResponseBody) -> StringBuilder {
  case body {
    Empty -> string_builder.new()
    Text(text) -> text
    File(path) -> {
      let assert Ok(contents) = simplifile.read(path)
      string_builder.from_string(contents)
    }
  }
}

// TODO: test
// TODO: document
pub fn body_to_bit_builder(body: ResponseBody) -> BitBuilder {
  case body {
    Empty -> bit_builder.new()
    Text(text) -> bit_builder.from_string_builder(text)
    File(path) -> {
      let assert Ok(contents) = simplifile.read_bits(path)
      bit_builder.from_bit_string(contents)
    }
  }
}