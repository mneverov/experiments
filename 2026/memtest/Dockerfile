FROM golang:1.27.3 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /memtest .

FROM gcr.io/distroless/static-debian12
COPY --from=build /memtest /memtest
ENTRYPOINT ["/memtest"]
